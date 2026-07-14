extends Node2D
class_name CapooSniperLockReticle

const RING_RADIUS := 18.0
const RING_WIDTH := 2.0
const RING_POINTS := 56
const RING_BACKGROUND := Color(0.24, 0.04, 0.02, 0.5)
const RING_PROGRESS := Color(1.0, 0.2, 0.08, 0.9)

@onready var center_mark: Sprite2D = $CenterMark

var duration: float = 3.0
var elapsed: float = 0.0
var auto_progress: bool = false
var progress_ratio: float = 0.0
var progress_display_active: bool = true


func _ready() -> void:
	set_process(false)
	_refresh_target_reticles()
	if progress_display_active:
		queue_redraw()


func start(new_duration: float, progress_automatically: bool = true) -> void:
	duration = maxf(new_duration, 0.01)
	elapsed = 0.0
	auto_progress = progress_automatically
	visible = true
	set_process(auto_progress)
	set_progress(0.0)


func stop() -> void:
	auto_progress = false
	set_process(false)
	queue_free()


func is_progress_display_active() -> bool:
	return progress_display_active


func set_progress(progress: float) -> void:
	var normalized_progress := clampf(progress, 0.0, 1.0)
	if is_equal_approx(progress_ratio, normalized_progress):
		return
	var was_progress_display_active := progress_display_active
	progress_ratio = normalized_progress
	_refresh_target_reticles()
	# A stable winner still needs one redraw for its changed arc. Visibility
	# transitions redraw inside _set_progress_display_active().
	if was_progress_display_active and progress_display_active:
		queue_redraw()


func _exit_tree() -> void:
	var parent_node := get_parent()
	if parent_node == null:
		return
	for child in parent_node.get_children():
		var reticle := child as CapooSniperLockReticle
		if reticle != null and reticle != self:
			reticle.call_deferred("_refresh_target_reticles")
			return


func _process(delta: float) -> void:
	if not auto_progress:
		return
	elapsed = minf(elapsed + delta, duration)
	set_progress(elapsed / duration)


func _draw() -> void:
	if not progress_display_active:
		return
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


func _refresh_target_reticles() -> void:
	var parent_node := get_parent()
	if parent_node == null:
		_set_progress_display_active(true)
		return
	var best_reticle := _get_highest_progress_reticle(parent_node)
	for child in parent_node.get_children():
		var reticle := child as CapooSniperLockReticle
		if reticle != null:
			reticle._set_progress_display_active(reticle == best_reticle)


func _get_highest_progress_reticle(parent_node: Node) -> CapooSniperLockReticle:
	var best_reticle: CapooSniperLockReticle = null
	for child in parent_node.get_children():
		var reticle := child as CapooSniperLockReticle
		if reticle == null:
			continue
		if best_reticle == null:
			best_reticle = reticle
			continue
		if reticle.progress_ratio > best_reticle.progress_ratio:
			best_reticle = reticle
			continue
		if is_equal_approx(reticle.progress_ratio, best_reticle.progress_ratio):
			if reticle.get_instance_id() > best_reticle.get_instance_id():
				best_reticle = reticle
	return best_reticle


func _set_progress_display_active(active: bool) -> void:
	if progress_display_active == active:
		return
	progress_display_active = active
	if is_node_ready():
		center_mark.visible = active
	queue_redraw()
