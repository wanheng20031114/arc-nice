extends ProductionBuilding
class_name ProductionProgressBorderBuilding

const BORDER_REVEAL_SECONDS := 0.15
const WORKING_ACTIVE_PARAMETER := &"working_active"
const PROGRESS_VALUE_PARAMETER := &"progress_value"
const PROGRESS_PROJECTION_PARAMETER := &"progress_projection"
const NOISE_SEED_PARAMETER := &"noise_seed"

@onready var production_border: MeshInstance2D = $ProductionBorder

var _border_reveal_tween: Tween = null


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
	production_border.hide()
	super._on_removal_started(mode)


func _sync_production_border(_replicate: bool = false) -> void:
	if production_border == null:
		return
	var recipe := get_active_recipe()
	var working := (
		is_operational
		and not is_dead
		and not is_removing
		and production_enabled
		and recipe != null
		and recipe.is_valid()
	)
	var projection := get_visual_progress_projection() if working else Vector4.ZERO
	production_border.set_instance_shader_parameter(
		WORKING_ACTIVE_PARAMETER,
		working
	)
	production_border.set_instance_shader_parameter(
		PROGRESS_VALUE_PARAMETER,
		projection.x
	)
	production_border.set_instance_shader_parameter(
		PROGRESS_PROJECTION_PARAMETER,
		Vector3(projection.y, projection.z, projection.w)
	)
	var seed_source := int(get_meta(&"net_id", get_instance_id()))
	production_border.set_instance_shader_parameter(
		NOISE_SEED_PARAMETER,
		float(posmod(seed_source * 37 + 11, 997)) / 997.0
	)


func _stop_border_reveal_tween() -> void:
	if _border_reveal_tween != null and _border_reveal_tween.is_valid():
		_border_reveal_tween.kill()
	_border_reveal_tween = null
