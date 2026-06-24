extends Node2D
class_name CapooSniperLockReticle

const RING_RADIUS := 18.0
const RING_WIDTH := 2.0
const RING_POINTS := 56
const RING_BACKGROUND := Color(0.24, 0.04, 0.02, 0.5)
const RING_PROGRESS := Color(1.0, 0.2, 0.08, 0.9)

var duration: float = 3.0
var elapsed: float = 0.0
var auto_progress: bool = false
var progress_ratio: float = 0.0


func _ready() -> void:
	set_process(false)
	set_progress(0.0)


func start(new_duration: float) -> void:
	duration = maxf(new_duration, 0.01)
	elapsed = 0.0
	auto_progress = true
	visible = true
	set_process(true)
	set_progress(0.0)


func stop() -> void:
	auto_progress = false
	set_process(false)
	queue_free()


func set_progress(progress: float) -> void:
	progress_ratio = clampf(progress, 0.0, 1.0)
	queue_redraw()


func _process(delta: float) -> void:
	if not auto_progress:
		return
	elapsed = minf(elapsed + delta, duration)
	set_progress(elapsed / duration)


func _draw() -> void:
	draw_arc(
		Vector2.ZERO,
		RING_RADIUS,
		-PI * 0.5,
		PI * 1.5,
		RING_POINTS,
		RING_BACKGROUND,
		RING_WIDTH
	)
	if progress_ratio <= 0.0:
		return
	draw_arc(
		Vector2.ZERO,
		RING_RADIUS,
		-PI * 0.5,
		-PI * 0.5 + TAU * progress_ratio,
		maxi(4, ceili(RING_POINTS * progress_ratio)),
		RING_PROGRESS,
		RING_WIDTH
	)
