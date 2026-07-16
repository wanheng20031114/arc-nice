extends Node
class_name CapooSniperLockVisualCoordinator

## Keeps the old per-reticle sibling scans available for deterministic A/B
## fixtures. Configure this before reticles enter the tree; it is deliberately
## not a live migration switch. Gameplay scenes leave this on.
@export var use_batched_arbitration: bool = true

var _reticles_by_target: Dictionary[int, Array] = {}
var _winner_by_target: Dictionary[int, WeakRef] = {}
var _dirty_targets: Dictionary[int, bool] = {}
var _pending_rebind_reticles: Array[WeakRef] = []
var _pending_rebind_ids: Dictionary[int, bool] = {}

var arbitration_pass_count: int = 0
var candidate_visit_count: int = 0
var winner_change_count: int = 0
var unregister_count: int = 0
var unregister_slot_lookup_count: int = 0
var unregister_swap_count: int = 0
var invalid_cleanup_count: int = 0
var repaired_binding_count: int = 0
var tracked_reticle_count: int = 0


func _ready() -> void:
	set_process(false)


func _exit_tree() -> void:
	# The coordinator can leave before the target/player subtree. Release every
	# local binding immediately so surviving reticles fall back to their sibling
	# arbitration instead of retaining a dead coordinator reference.
	for reticles_variant in _reticles_by_target.values():
		var reticles := reticles_variant as Array
		var refresh_source: CapooSniperLockReticle = null
		for reticle_variant in reticles:
			var reticle := reticle_variant as CapooSniperLockReticle
			if reticle == null or not is_instance_valid(reticle):
				continue
			reticle.release_coordinator_binding(self)
			refresh_source = reticle
		if refresh_source != null:
			refresh_source.refresh_uncoordinated_target_reticles()
	_reticles_by_target.clear()
	_winner_by_target.clear()
	_dirty_targets.clear()
	_pending_rebind_reticles.clear()
	_pending_rebind_ids.clear()
	tracked_reticle_count = 0


func register_reticle(reticle: CapooSniperLockReticle) -> bool:
	if not use_batched_arbitration or reticle == null or not is_instance_valid(reticle):
		return false
	var runtime_root := get_parent()
	if runtime_root == null or not runtime_root.is_ancestor_of(reticle):
		return false
	var target := reticle.get_parent()
	if target == null:
		return false
	var target_id := target.get_instance_id()
	var reticles: Array
	if _reticles_by_target.has(target_id):
		reticles = _reticles_by_target[target_id] as Array
	else:
		reticles = []
		_reticles_by_target[target_id] = reticles
	var slot_index := reticles.size()
	reticles.append(reticle)
	reticle.set_coordinator_slot(target_id, slot_index)
	tracked_reticle_count += 1
	reticle.apply_coordinated_winner_state(false)
	_mark_target_dirty(target_id)
	return true


func unregister_reticle(reticle: CapooSniperLockReticle, _target: Node = null) -> void:
	if reticle == null:
		return
	var target_id := reticle.get_coordinated_target_id()
	var slot_index := reticle.get_coordinator_slot_index()
	unregister_count += 1
	unregister_slot_lookup_count += 1
	if target_id <= 0 or slot_index < 0:
		return
	if not _reticles_by_target.has(target_id):
		# The coordinator may leave the tree before a later sibling during scene
		# teardown. Its registry is already gone, so only clear the local binding.
		reticle.release_coordinator_binding(self)
		return
	var reticles := _reticles_by_target[target_id] as Array
	if slot_index >= reticles.size() or reticles[slot_index] != reticle:
		push_error("Sniper lock coordinator slot invariant was broken during unregister.")
		return
	_swap_pop_slot(reticles, slot_index, reticle)
	if reticles.is_empty():
		_reticles_by_target.erase(target_id)
	var winner := _get_winner(target_id)
	if winner == reticle:
		_winner_by_target.erase(target_id)
		reticle.apply_coordinated_winner_state(false)
	_mark_target_dirty(target_id)


func notify_progress_changed(reticle: CapooSniperLockReticle) -> void:
	if reticle == null or not is_instance_valid(reticle):
		return
	_mark_target_dirty(reticle.get_coordinated_target_id())


func flush_pending_updates() -> void:
	if _dirty_targets.is_empty() and _pending_rebind_reticles.is_empty():
		set_process(false)
		return
	# No keys() copy: progress changes are already coalesced in this persistent
	# dictionary, and refresh does not enqueue another target synchronously.
	for target_id_variant in _dirty_targets:
		_refresh_target(int(target_id_variant))
	_dirty_targets.clear()
	_rebind_repaired_reticles()
	# Re-registration marks the reticle's real parent target dirty. Arbitrate that
	# target on the next process slice rather than mutating the Dictionary while
	# it is being traversed above.
	set_process(not _dirty_targets.is_empty())


func reset_metrics() -> void:
	arbitration_pass_count = 0
	candidate_visit_count = 0
	winner_change_count = 0
	unregister_count = 0
	unregister_slot_lookup_count = 0
	unregister_swap_count = 0
	invalid_cleanup_count = 0
	repaired_binding_count = 0


func get_metrics() -> Dictionary:
	return {
		"arbitration_passes": arbitration_pass_count,
		"candidate_visits": candidate_visit_count,
		"winner_changes": winner_change_count,
		"unregister_count": unregister_count,
		"unregister_slot_lookups": unregister_slot_lookup_count,
		"unregister_swaps": unregister_swap_count,
		"invalid_cleanups": invalid_cleanup_count,
		"repaired_bindings": repaired_binding_count,
		"tracked_reticles": tracked_reticle_count,
		"tracked_targets": _reticles_by_target.size(),
		"dirty_targets": _dirty_targets.size(),
	}


func _process(_delta: float) -> void:
	flush_pending_updates()


func _mark_target_dirty(target_id: int) -> void:
	if target_id <= 0:
		return
	_dirty_targets[target_id] = true
	set_process(true)


func _refresh_target(target_id: int) -> void:
	if not _reticles_by_target.has(target_id):
		arbitration_pass_count += 1
		_winner_by_target.erase(target_id)
		return
	var reticles := _reticles_by_target[target_id] as Array
	var best_reticle: CapooSniperLockReticle = null
	var index := 0
	while index < reticles.size():
		var candidate := reticles[index] as CapooSniperLockReticle
		if (
			candidate == null
			or not is_instance_valid(candidate)
			or candidate.get_coordinated_target_id() != target_id
		):
			invalid_cleanup_count += 1
			_swap_pop_slot(reticles, index, candidate)
			if candidate != null and is_instance_valid(candidate):
				_queue_reticle_rebind(candidate)
			continue
		candidate_visit_count += 1
		if _has_higher_priority(candidate, best_reticle):
			best_reticle = candidate
		index += 1

	if reticles.is_empty():
		_reticles_by_target.erase(target_id)
	arbitration_pass_count += 1

	var previous_winner := _get_winner(target_id)
	if previous_winner != best_reticle:
		winner_change_count += 1
		if previous_winner != null and is_instance_valid(previous_winner):
			previous_winner.apply_coordinated_winner_state(false)
		if best_reticle == null:
			_winner_by_target.erase(target_id)
		else:
			_winner_by_target[target_id] = weakref(best_reticle)
	if best_reticle != null:
		best_reticle.apply_coordinated_winner_state(true)


func _queue_reticle_rebind(reticle: CapooSniperLockReticle) -> void:
	if reticle == null or not is_instance_valid(reticle):
		return
	var instance_id := reticle.get_instance_id()
	if _pending_rebind_ids.has(instance_id):
		return
	_pending_rebind_ids[instance_id] = true
	_pending_rebind_reticles.append(weakref(reticle))


func _rebind_repaired_reticles() -> void:
	if _pending_rebind_reticles.is_empty():
		return
	var pending := _pending_rebind_reticles
	_pending_rebind_reticles = []
	_pending_rebind_ids.clear()
	for reticle_ref in pending:
		var reticle := reticle_ref.get_ref() as CapooSniperLockReticle
		if (
			reticle == null
			or not is_instance_valid(reticle)
			or not reticle.is_inside_tree()
			or reticle.is_queued_for_deletion()
		):
			continue
		if reticle.try_restore_coordinator_binding():
			repaired_binding_count += 1


func _swap_pop_slot(
	reticles: Array,
	slot_index: int,
	removed_reticle: CapooSniperLockReticle
) -> void:
	var last_index := reticles.size() - 1
	if slot_index != last_index:
		var moved_reticle := reticles[last_index] as CapooSniperLockReticle
		reticles[slot_index] = moved_reticle
		if moved_reticle != null and is_instance_valid(moved_reticle):
			moved_reticle.set_coordinator_slot(
				moved_reticle.get_coordinated_target_id(),
				slot_index
			)
		unregister_swap_count += 1
	reticles.pop_back()
	tracked_reticle_count = maxi(tracked_reticle_count - 1, 0)
	if removed_reticle != null and is_instance_valid(removed_reticle):
		# A valid reticle can reach this path after a stale target/slot binding is
		# detected. Release the complete coordinator state, not just its numeric
		# slot, so subsequent progress changes use the safe sibling fallback.
		removed_reticle.release_coordinator_binding(self)


func _get_winner(target_id: int) -> CapooSniperLockReticle:
	var winner_ref := _winner_by_target.get(target_id) as WeakRef
	if winner_ref == null:
		return null
	var winner := winner_ref.get_ref() as CapooSniperLockReticle
	return winner if winner != null and is_instance_valid(winner) else null


func _has_higher_priority(
	candidate: CapooSniperLockReticle,
	current_best: CapooSniperLockReticle
) -> bool:
	if current_best == null:
		return true
	if candidate.progress_ratio > current_best.progress_ratio:
		return true
	return (
		is_equal_approx(candidate.progress_ratio, current_best.progress_ratio)
		and candidate.get_instance_id() > current_best.get_instance_id()
	)
