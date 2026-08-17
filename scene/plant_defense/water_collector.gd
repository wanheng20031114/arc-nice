extends ProductionBuilding
class_name WaterCollector

const PROGRESS_EPSILON := 0.0001

@onready var collection_progress_ring: TextureProgressBar = (
	$VisualRoot/CollectionProgressRing
)

var _collection_progress_tween: Tween = null


func _ready() -> void:
	super._ready()
	if not production_state_changed.is_connected(_sync_collection_progress):
		production_state_changed.connect(_sync_collection_progress)
	_sync_collection_progress()


func _on_setup_completed() -> void:
	super._on_setup_completed()
	_sync_collection_progress()


func _on_construction_started() -> void:
	_stop_collection_progress_tween()
	collection_progress_ring.hide()


func _on_construction_finished(_was_animated: bool) -> void:
	_sync_collection_progress()


func _on_operational_started() -> void:
	super._on_operational_started()
	_sync_collection_progress()


func _on_removal_started(mode: RemovalMode) -> void:
	_stop_collection_progress_tween()
	collection_progress_ring.hide()
	super._on_removal_started(mode)


func _sync_collection_progress(_replicate: bool = false) -> void:
	if collection_progress_ring == null:
		return
	_stop_collection_progress_tween()
	var recipe := get_active_recipe()
	var can_show := is_operational and not is_dead and not is_removing
	var is_collecting := (
		can_show
		and production_enabled
		and recipe != null
		and recipe.is_valid()
	)
	collection_progress_ring.visible = can_show
	var progress_start := get_progress_ratio() if is_collecting else 0.0
	collection_progress_ring.value = progress_start
	if (
		not is_collecting
		or completion_wait_reason != &""
		or progress_start >= 1.0 - PROGRESS_EPSILON
	):
		return
	var progress_target := minf(
		progress_start
		+ VISUAL_PROJECTION_WINDOW_SECONDS
		/ get_production_duration_multiplier()
		/ recipe.duration_seconds,
		1.0
	)
	if progress_target <= progress_start + PROGRESS_EPSILON:
		return
	_collection_progress_tween = create_tween()
	_collection_progress_tween.set_trans(Tween.TRANS_LINEAR)
	_collection_progress_tween.tween_property(
		collection_progress_ring,
		"value",
		progress_target,
		get_visual_projection_duration_seconds()
	)


func _stop_collection_progress_tween() -> void:
	if (
		_collection_progress_tween != null
		and _collection_progress_tween.is_valid()
	):
		_collection_progress_tween.kill()
	_collection_progress_tween = null
