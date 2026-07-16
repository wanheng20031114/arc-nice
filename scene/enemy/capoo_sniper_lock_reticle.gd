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
var draw_progress_ratio: float = 0.0
var draw_progress_segment: int = 0
var _coordinator: CapooSniperLockVisualCoordinator = null
var _coordinated_target_id: int = 0
var _coordinator_slot_index: int = -1
var _uses_coordinated_arbitration: bool = false


func _ready() -> void:
	set_process(false)
	draw_progress_segment = _quantize_progress_segment(progress_ratio)
	draw_progress_ratio = float(draw_progress_segment) / float(RING_POINTS)
	_uses_coordinated_arbitration = _try_register_with_coordinator()
	if not _uses_coordinated_arbitration:
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
	if _uses_coordinated_arbitration and is_instance_valid(_coordinator):
		_coordinator.notify_progress_changed(self)
		return
	_uses_coordinated_arbitration = false
	_refresh_target_reticles()
	# A stable winner still needs one redraw for its changed arc. Visibility
	# transitions redraw inside _set_progress_display_active().
	if was_progress_display_active and progress_display_active:
		queue_redraw()


func _exit_tree() -> void:
	var parent_node := get_parent()
	if _uses_coordinated_arbitration and is_instance_valid(_coordinator):
		_coordinator.unregister_reticle(self, parent_node)
		_coordinator = null
		_uses_coordinated_arbitration = false
		return
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
	var rendered_progress := draw_progress_ratio if _uses_coordinated_arbitration else progress_ratio
	if rendered_progress <= 0.0:
		return
	draw_arc(
		Vector2.ZERO,
		RING_RADIUS,
		-PI * 0.5,
		-PI * 0.5 + TAU * rendered_progress,
		maxi(4, ceili(RING_POINTS * rendered_progress)),
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


func apply_coordinated_winner_state(active: bool) -> void:
	var next_segment := _quantize_progress_segment(progress_ratio)
	var visibility_changed := progress_display_active != active
	var progress_changed := active and draw_progress_segment != next_segment
	if not visibility_changed and not progress_changed:
		return
	progress_display_active = active
	if active:
		draw_progress_segment = next_segment
		draw_progress_ratio = float(next_segment) / float(RING_POINTS)
	if is_node_ready():
		center_mark.visible = active
	queue_redraw()


func get_coordinated_target_id() -> int:
	return _coordinated_target_id


func get_coordinator_slot_index() -> int:
	return _coordinator_slot_index


func set_coordinator_slot(target_id: int, slot_index: int) -> void:
	_coordinated_target_id = target_id
	_coordinator_slot_index = slot_index


func clear_coordinator_slot() -> void:
	_coordinated_target_id = 0
	_coordinator_slot_index = -1


func release_coordinator_binding(
	coordinator: CapooSniperLockVisualCoordinator
) -> void:
	if _coordinator != coordinator:
		return
	_coordinator = null
	_uses_coordinated_arbitration = false
	clear_coordinator_slot()


func try_restore_coordinator_binding() -> bool:
	if _uses_coordinated_arbitration and is_instance_valid(_coordinator):
		return true
	_coordinator = null
	_uses_coordinated_arbitration = _try_register_with_coordinator()
	if _uses_coordinated_arbitration:
		return true
	# No owning coordinator remains. Keep the reticle functional instead of
	# retaining a half-bound state; every sibling in this scope will use the same
	# fallback once its coordinator is absent.
	_refresh_target_reticles()
	if progress_display_active:
		queue_redraw()
	return false


func refresh_uncoordinated_target_reticles() -> void:
	if _uses_coordinated_arbitration:
		return
	_refresh_target_reticles()


func uses_coordinated_arbitration() -> bool:
	return _uses_coordinated_arbitration


func _try_register_with_coordinator() -> bool:
	var parent_node := get_parent()
	if parent_node == null:
		return false
	_coordinator = _find_runtime_coordinator(parent_node)
	if _coordinator == null:
		return false
	if not _coordinator.register_reticle(self):
		_coordinator = null
		return false
	return true


func _find_runtime_coordinator(
	start_node: Node
) -> CapooSniperLockVisualCoordinator:
	# Gameplay scenes author one coordinator as a direct child of their runtime
	# root. Walking upward and inspecting only direct children selects the
	# nearest owning runtime and cannot cross into a sibling game instance.
	var scope := start_node
	while scope != null:
		for child in scope.get_children():
			var coordinator := child as CapooSniperLockVisualCoordinator
			if coordinator != null and coordinator.is_inside_tree():
				return coordinator
		scope = scope.get_parent()
	return null


func _quantize_progress_segment(progress: float) -> int:
	return clampi(roundi(clampf(progress, 0.0, 1.0) * float(RING_POINTS)), 0, RING_POINTS)
