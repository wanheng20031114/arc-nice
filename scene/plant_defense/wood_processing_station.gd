extends ProductionBuilding
class_name WoodProcessingStation

const BORDER_REVEAL_SECONDS := 0.15
const WORKING_ACTIVE_PARAMETER := &"working_active"
const PROGRESS_VALUE_PARAMETER := &"progress_value"
const NOISE_SEED_PARAMETER := &"noise_seed"

@onready var production_border: MeshInstance2D = $ProductionBorder

var _border_reveal_tween: Tween = null
var _border_progress_tween: Tween = null


func _ready() -> void:
	super._ready()
	if not production_state_changed.is_connected(_sync_production_border):
		production_state_changed.connect(_sync_production_border)
	_sync_production_border()


func _on_setup_completed() -> void:
	super._on_setup_completed()
	_sync_production_border()


func _on_construction_started() -> void:
	_stop_border_reveal_tween()
	_stop_border_progress_tween()
	production_border.hide()


func _on_construction_finished(was_animated: bool) -> void:
	_sync_production_border()
	if not was_animated:
		production_border.modulate.a = 1.0
		production_border.show()
		return
	production_border.modulate.a = 0.0
	production_border.show()
	_border_reveal_tween = create_tween()
	_border_reveal_tween.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_OUT)
	_border_reveal_tween.tween_property(
		production_border,
		"modulate:a",
		1.0,
		BORDER_REVEAL_SECONDS
	)


func _on_operational_started() -> void:
	super._on_operational_started()
	_sync_production_border()


func _on_removal_started(mode: RemovalMode) -> void:
	_stop_border_reveal_tween()
	_stop_border_progress_tween()
	production_border.hide()
	super._on_removal_started(mode)


func _sync_production_border() -> void:
	if production_border == null:
		return
	_stop_border_progress_tween()
	var recipe := get_active_recipe()
	var working := (
		is_operational
		and not is_dead
		and not is_removing
		and production_enabled
		and recipe != null
		and recipe.is_valid()
	)
	# State-change signals are emitted immediately after the authoritative
	# one-second value is committed. Starting the Tween from that exact value
	# avoids introducing a millisecond-sized offset before its first frame.
	var progress_start := get_progress_ratio() if working else 0.0
	var progress_target := progress_start
	if (
		working
		and completion_wait_reason == &""
		and progress_start < 1.0
	):
		progress_target = minf(
			progress_start
			+ VISUAL_PROJECTION_WINDOW_SECONDS / recipe.duration_seconds,
			1.0
		)
	production_border.set_instance_shader_parameter(
		WORKING_ACTIVE_PARAMETER,
		working
	)
	production_border.set_instance_shader_parameter(
		PROGRESS_VALUE_PARAMETER,
		progress_start
	)
	var seed_source := int(get_meta(&"net_id", get_instance_id()))
	production_border.set_instance_shader_parameter(
		NOISE_SEED_PARAMETER,
		float(posmod(seed_source * 37 + 11, 997)) / 997.0
	)
	if progress_target > progress_start + 0.0001:
		_border_progress_tween = create_tween()
		_border_progress_tween.set_trans(Tween.TRANS_LINEAR)
		_border_progress_tween.tween_method(
			_set_border_progress,
			progress_start,
			progress_target,
			get_visual_projection_duration_seconds()
		)


func _set_border_progress(progress: float) -> void:
	if production_border == null:
		return
	production_border.set_instance_shader_parameter(
		PROGRESS_VALUE_PARAMETER,
		progress
	)


func _stop_border_reveal_tween() -> void:
	if _border_reveal_tween != null and _border_reveal_tween.is_valid():
		_border_reveal_tween.kill()
	_border_reveal_tween = null


func _stop_border_progress_tween() -> void:
	if _border_progress_tween != null and _border_progress_tween.is_valid():
		_border_progress_tween.kill()
	_border_progress_tween = null
