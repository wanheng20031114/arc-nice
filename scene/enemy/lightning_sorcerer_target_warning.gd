extends Node2D
class_name LightningSorcererTargetWarning

## Scene-authored, externally driven target telegraph for the lightning sorcerer.
## The owner supplies world position and normalized progress; this node never
## starts its own process loop and therefore stays dormant while hidden.

const PRIMARY_START_RADIUS := 27.0
const PRIMARY_END_RADIUS := 17.0
const DEFAULT_CHAIN_DANGER_RADIUS := 48.0
const PRIMARY_ARC_HALF_GAP := 0.18
const CHAIN_ARC_HALF_WIDTH := 0.22
const DIRECTION_MARK_OUTER_OFFSET := 5.0
const DIRECTION_MARK_INNER_OFFSET := 1.0
const DIRECTION_MARK_HALF_WIDTH := 3.0

const GOLD := Color(1.0, 0.82, 0.12, 1.0)
const PALE_CYAN := Color(0.56, 1.0, 0.96, 1.0)

var _warning_active := false
var _warning_duration := 0.0
var _warning_progress := 0.0
var _chain_danger_radius := DEFAULT_CHAIN_DANGER_RADIUS


func _ready() -> void:
	set_process(false)
	hide()


## Activates the prebuilt marker at a world-space position. Progress remains
## externally controlled so local authority and remote playback share one API.
func start_warning(
	world_position: Vector2,
	duration: float,
	chain_danger_radius: float = DEFAULT_CHAIN_DANGER_RADIUS
) -> void:
	_warning_active = true
	_warning_duration = maxf(duration, 0.001)
	_warning_progress = 0.0
	_chain_danger_radius = maxf(chain_danger_radius, 0.0)
	global_position = world_position.round()
	show()
	queue_redraw()


## Moves the marker and updates its normalized windup progress.
func update_warning(world_position: Vector2, progress: float) -> void:
	if not _warning_active:
		return
	global_position = world_position.round()
	_warning_progress = clampf(progress, 0.0, 1.0)
	queue_redraw()


func clear_warning() -> void:
	if not _warning_active and not visible:
		return
	_warning_active = false
	_warning_duration = 0.0
	_warning_progress = 0.0
	_chain_danger_radius = DEFAULT_CHAIN_DANGER_RADIUS
	hide()


func is_warning_active() -> bool:
	return _warning_active


func get_warning_duration() -> float:
	return _warning_duration


func get_warning_progress() -> float:
	return _warning_progress


func get_progress_ratio() -> float:
	return _warning_progress


func get_chain_danger_radius() -> float:
	return _chain_danger_radius


func _draw() -> void:
	if not _warning_active:
		return

	var progress := _warning_progress
	var pulse := 0.5 + 0.5 * sin(progress * TAU * 2.0)
	var primary_radius := lerpf(PRIMARY_START_RADIUS, PRIMARY_END_RADIUS, progress)
	var primary_alpha := lerpf(0.42, 0.92, progress) * lerpf(0.86, 1.0, pulse)
	var marker_alpha := lerpf(0.36, 0.86, progress)
	var chain_alpha := lerpf(0.10, 0.17, progress) * lerpf(0.86, 1.0, pulse)

	# Eight alternating broken arcs keep the target readable without an opaque fill.
	for segment_index in range(8):
		var center_angle := float(segment_index) * TAU / 8.0
		var segment_color := GOLD if segment_index % 2 == 0 else PALE_CYAN
		segment_color.a = primary_alpha
		draw_arc(
			Vector2.ZERO,
			primary_radius,
			center_angle - TAU / 16.0 + PRIMARY_ARC_HALF_GAP,
			center_angle + TAU / 16.0 - PRIMARY_ARC_HALF_GAP,
			5,
			segment_color,
			2.0,
			false
		)

	# Four inward-facing brackets make the lock direction obvious at a glance.
	for direction_index in range(4):
		var direction := Vector2.RIGHT.rotated(float(direction_index) * TAU / 4.0)
		var tangent := direction.orthogonal()
		var outer_center := direction * (primary_radius + DIRECTION_MARK_OUTER_OFFSET)
		var inner_tip := direction * (primary_radius + DIRECTION_MARK_INNER_OFFSET)
		var marker_color := PALE_CYAN if direction_index % 2 == 0 else GOLD
		marker_color.a = marker_alpha
		draw_line(
			outer_center + tangent * DIRECTION_MARK_HALF_WIDTH,
			inner_tip,
			marker_color,
			1.5,
			false
		)
		draw_line(
			outer_center - tangent * DIRECTION_MARK_HALF_WIDTH,
			inner_tip,
			marker_color,
			1.5,
			false
		)

	# The faint outer broken circle previews the configured radius in which lightning can
	# acquire its first follow-up target. It is a risk hint, not a guarantee that
	# every unit inside will be selected or a boundary for the complete chain.
	if _chain_danger_radius <= 0.0:
		return
	for quadrant_index in range(4):
		var quadrant_center := float(quadrant_index) * TAU / 4.0 + TAU / 8.0
		var danger_color := GOLD if quadrant_index % 2 == 0 else PALE_CYAN
		danger_color.a = chain_alpha
		draw_arc(
			Vector2.ZERO,
			_chain_danger_radius,
			quadrant_center - CHAIN_ARC_HALF_WIDTH,
			quadrant_center + CHAIN_ARC_HALF_WIDTH,
			5,
			danger_color,
			1.0,
			false
		)
