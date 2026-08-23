extends Node2D
class_name EnemyWarningPresentationSystem

enum Family {
	INVALID,
	LIGHTNING_RING,
	SNIPER_LINE,
	SNIPER_RETICLE,
}

const INVALID_HANDLE := 0
const INVALID_SLOT := -1
const HANDLE_SLOT_BITS := 32
const HANDLE_SLOT_MASK := 0xFFFFFFFF
const MAX_GENERATION := 0x7FFFFFFF
const MIN_LOGICAL_GROWTH := 64
const LIGHTNING_VISUAL_CAPACITY := 512
const SNIPER_LINE_VISUAL_CAPACITY := 1024
const SNIPER_RETICLE_VISUAL_CAPACITY := 1024
const LIGHTNING_QUAD_HALF_SIZE := 64.0
const SNIPER_RETICLE_RADIUS := 18.0

@onready var lightning_multimesh_instance: MultiMeshInstance2D = $LightningWarnings
@onready var sniper_line_multimesh_instance: MultiMeshInstance2D = $SniperLines
@onready var sniper_reticle_multimesh_instance: MultiMeshInstance2D = $SniperReticles

var _combat_runtime: CombatRuntimeBase = null
var _enemy_simulation_coordinator: EnemySimulationCoordinator = null
var _headless_disabled := false
var _teardown_prepared := false
var _teardown_count := 0

# Logical warning slots grow independently from the three fixed draw buffers.
var _slot_states := PackedByteArray()
var _slot_generations := PackedInt32Array()
var _families := PackedInt32Array()
var _owner_ids := PackedInt64Array()
var _target_ids := PackedInt64Array()
var _positions_a := PackedVector2Array()
var _positions_b := PackedVector2Array()
var _progresses := PackedFloat32Array()
var _chain_radii := PackedFloat32Array()
var _free_slots := PackedInt32Array()
var _logical_capacity := 0
var _logical_slot_count := 0
var _free_slot_count := 0
var _live_count := 0

var _reticle_winners: Dictionary[int, int] = {}
var _last_lightning_visible := 0
var _last_line_visible := 0
var _last_reticle_visible := 0
var _last_lightning_drops := 0
var _last_line_drops := 0
var _last_reticle_drops := 0
var _metric_acquisitions := 0
var _metric_acquisition_rejections := 0
var _metric_updates := 0
var _metric_update_rejections := 0
var _metric_releases := 0
var _metric_flushes := 0
var _metric_visual_writes := 0
var _metric_headless_flush_skips := 0
var _metric_reticle_arbitrations := 0
var _metric_reticle_losers := 0


func _init() -> void:
	_headless_disabled = _is_headless_display()
	set_process(false)
	set_physics_process(false)


func _ready() -> void:
	if _headless_disabled or _teardown_prepared:
		_disable_visual_storage()
		return
	var lightning := _get_lightning_multimesh()
	var lines := _get_line_multimesh()
	var reticles := _get_reticle_multimesh()
	if (
		not _is_valid_authored_multimesh(lightning)
		or not _is_valid_authored_multimesh(lines)
		or not _is_valid_authored_multimesh(reticles)
	):
		push_error("EnemyWarningPresentationSystem authored MultiMesh contracts are invalid.")
		_disable_visual_storage()
		return
	lightning.instance_count = LIGHTNING_VISUAL_CAPACITY
	lightning.visible_instance_count = 0
	lines.instance_count = SNIPER_LINE_VISUAL_CAPACITY
	lines.visible_instance_count = 0
	reticles.instance_count = SNIPER_RETICLE_VISUAL_CAPACITY
	reticles.visible_instance_count = 0


func bind_context(
	runtime: CombatRuntimeBase,
	coordinator: EnemySimulationCoordinator
) -> bool:
	if (
		_teardown_prepared
		or runtime == null
		or coordinator == null
		or not is_instance_valid(runtime)
		or not is_instance_valid(coordinator)
		or coordinator.get_parent() != runtime
	):
		return false
	if _combat_runtime != null and (
		_combat_runtime != runtime or _enemy_simulation_coordinator != coordinator
	):
		return false
	_combat_runtime = runtime
	_enemy_simulation_coordinator = coordinator
	return true


func is_bound() -> bool:
	return (
		_combat_runtime != null
		and _enemy_simulation_coordinator != null
		and is_instance_valid(_combat_runtime)
		and is_instance_valid(_enemy_simulation_coordinator)
	)


func acquire_lightning_warning(owner_id: int) -> int:
	return _acquire_warning(Family.LIGHTNING_RING, owner_id, 0)


func update_lightning_warning(
	handle: int,
	position: Vector2,
	progress: float,
	chain_radius: float
) -> bool:
	var slot := _resolve_slot_for_family(handle, Family.LIGHTNING_RING)
	if (
		slot < 0
		or not position.is_finite()
		or not is_finite(progress)
		or not is_finite(chain_radius)
		or chain_radius < 0.0
	):
		_metric_update_rejections += 1
		return false
	_positions_a[slot] = position
	_progresses[slot] = clampf(progress, 0.0, 1.0)
	_chain_radii[slot] = chain_radius
	_metric_updates += 1
	return true


func acquire_sniper_line(owner_id: int) -> int:
	return _acquire_warning(Family.SNIPER_LINE, owner_id, 0)


func update_sniper_line(
	handle: int,
	start: Vector2,
	end: Vector2,
	progress: float
) -> bool:
	var slot := _resolve_slot_for_family(handle, Family.SNIPER_LINE)
	if slot < 0 or not start.is_finite() or not end.is_finite() or not is_finite(progress):
		_metric_update_rejections += 1
		return false
	_positions_a[slot] = start
	_positions_b[slot] = end
	_progresses[slot] = clampf(progress, 0.0, 1.0)
	_metric_updates += 1
	return true


func acquire_sniper_reticle(owner_id: int, target_id: int) -> int:
	return _acquire_warning(Family.SNIPER_RETICLE, owner_id, target_id)


func update_sniper_reticle(handle: int, position: Vector2, progress: float) -> bool:
	var slot := _resolve_slot_for_family(handle, Family.SNIPER_RETICLE)
	if slot < 0 or not position.is_finite() or not is_finite(progress):
		_metric_update_rejections += 1
		return false
	_positions_a[slot] = position
	_progresses[slot] = clampf(progress, 0.0, 1.0)
	_metric_updates += 1
	return true


func release_warning(handle: int) -> bool:
	var slot := _resolve_slot(handle)
	if slot < 0:
		return false
	_slot_states[slot] = 0
	_families[slot] = Family.INVALID
	_free_slots[_free_slot_count] = slot
	_free_slot_count += 1
	_live_count = maxi(_live_count - 1, 0)
	_metric_releases += 1
	return true


func is_handle_live(handle: int) -> bool:
	return _resolve_slot(handle) >= 0


func get_handle_family(handle: int) -> Family:
	var slot := _resolve_slot(handle)
	return int(_families[slot]) as Family if slot >= 0 else Family.INVALID


func get_handle_owner_id(handle: int) -> int:
	var slot := _resolve_slot(handle)
	return int(_owner_ids[slot]) if slot >= 0 else 0


func get_sniper_reticle_winner_handle(target_id: int) -> int:
	var winner_slot := _find_reticle_winner_slot(target_id)
	return _encode_handle(winner_slot) if winner_slot >= 0 else INVALID_HANDLE


func flush_presenter() -> int:
	if _headless_disabled:
		_metric_headless_flush_skips += 1
		return 0
	if _is_headless_display():
		_headless_disabled = true
		_metric_headless_flush_skips += 1
		_disable_visual_storage()
		return 0
	if _teardown_prepared or not is_inside_tree() or not is_visible_in_tree():
		_clear_visible_prefixes()
		return 0
	var lightning := _get_lightning_multimesh()
	var lines := _get_line_multimesh()
	var reticles := _get_reticle_multimesh()
	if (
		lightning == null
		or lines == null
		or reticles == null
		or lightning.instance_count != LIGHTNING_VISUAL_CAPACITY
		or lines.instance_count != SNIPER_LINE_VISUAL_CAPACITY
		or reticles.instance_count != SNIPER_RETICLE_VISUAL_CAPACITY
	):
		_clear_visible_prefixes()
		return 0
	_metric_flushes += 1
	_reset_last_flush_metrics()
	_rebuild_reticle_winners()
	for slot in range(_logical_slot_count):
		if _slot_states[slot] == 0:
			continue
		match int(_families[slot]) as Family:
			Family.LIGHTNING_RING:
				_write_lightning(slot, lightning)
			Family.SNIPER_LINE:
				_write_sniper_line(slot, lines)
			Family.SNIPER_RETICLE:
				if int(_reticle_winners.get(int(_target_ids[slot]), INVALID_SLOT)) == slot:
					_write_sniper_reticle(slot, reticles)
				else:
					_metric_reticle_losers += 1
	lightning.visible_instance_count = _last_lightning_visible
	lines.visible_instance_count = _last_line_visible
	reticles.visible_instance_count = _last_reticle_visible
	var visible_total := _last_lightning_visible + _last_line_visible + _last_reticle_visible
	_metric_visual_writes += visible_total
	return visible_total


func _write_lightning(slot: int, multimesh: MultiMesh) -> void:
	if _last_lightning_visible >= LIGHTNING_VISUAL_CAPACITY:
		_last_lightning_drops += 1
		return
	var chain_radius := maxf(float(_chain_radii[slot]), 0.0)
	var outer_radius := maxf(chain_radius, 32.0)
	var scale_factor := outer_radius / LIGHTNING_QUAD_HALF_SIZE
	var transform := Transform2D(0.0, to_local(_positions_a[slot]))
	transform = transform.scaled_local(Vector2.ONE * scale_factor)
	multimesh.set_instance_transform_2d(_last_lightning_visible, transform)
	multimesh.set_instance_custom_data(
		_last_lightning_visible,
		Color(_progresses[slot], chain_radius / outer_radius, outer_radius, 1.0)
	)
	_last_lightning_visible += 1


func _write_sniper_line(slot: int, multimesh: MultiMesh) -> void:
	if _last_line_visible >= SNIPER_LINE_VISUAL_CAPACITY:
		_last_line_drops += 1
		return
	var local_start := to_local(_positions_a[slot])
	var local_end := to_local(_positions_b[slot])
	var delta := local_end - local_start
	if delta.length_squared() <= 0.001:
		return
	var transform := Transform2D(delta.angle(), (local_start + local_end) * 0.5)
	transform = transform.scaled_local(Vector2(delta.length(), 1.0))
	multimesh.set_instance_transform_2d(_last_line_visible, transform)
	multimesh.set_instance_custom_data(
		_last_line_visible,
		Color(_progresses[slot], 0.0, 0.0, 1.0)
	)
	_last_line_visible += 1


func _write_sniper_reticle(slot: int, multimesh: MultiMesh) -> void:
	if _last_reticle_visible >= SNIPER_RETICLE_VISUAL_CAPACITY:
		_last_reticle_drops += 1
		return
	multimesh.set_instance_transform_2d(
		_last_reticle_visible,
		Transform2D(0.0, to_local(_positions_a[slot]))
	)
	multimesh.set_instance_custom_data(
		_last_reticle_visible,
		Color(_progresses[slot], 0.0, 0.0, 1.0)
	)
	_last_reticle_visible += 1


func _rebuild_reticle_winners() -> void:
	_reticle_winners.clear()
	for slot in range(_logical_slot_count):
		if _slot_states[slot] == 0 or _families[slot] != Family.SNIPER_RETICLE:
			continue
		var target_id := int(_target_ids[slot])
		var current := int(_reticle_winners.get(target_id, INVALID_SLOT))
		if current < 0 or _reticle_has_higher_priority(slot, current):
			_reticle_winners[target_id] = slot
	_metric_reticle_arbitrations += _reticle_winners.size()


func _find_reticle_winner_slot(target_id: int) -> int:
	var winner := INVALID_SLOT
	for slot in range(_logical_slot_count):
		if (
			_slot_states[slot] == 0
			or _families[slot] != Family.SNIPER_RETICLE
			or _target_ids[slot] != target_id
		):
			continue
		if winner < 0 or _reticle_has_higher_priority(slot, winner):
			winner = slot
	return winner


func _reticle_has_higher_priority(candidate: int, current: int) -> bool:
	var candidate_progress := float(_progresses[candidate])
	var current_progress := float(_progresses[current])
	if not is_equal_approx(candidate_progress, current_progress):
		return candidate_progress > current_progress
	if _owner_ids[candidate] != _owner_ids[current]:
		return _owner_ids[candidate] > _owner_ids[current]
	return candidate > current


func _acquire_warning(family: Family, owner_id: int, target_id: int) -> int:
	if (
		_teardown_prepared
		or family == Family.INVALID
		or owner_id <= 0
		or (family == Family.SNIPER_RETICLE and target_id <= 0)
	):
		_metric_acquisition_rejections += 1
		return INVALID_HANDLE
	var slot := INVALID_SLOT
	if _free_slot_count > 0:
		_free_slot_count -= 1
		slot = int(_free_slots[_free_slot_count])
	else:
		if _logical_slot_count >= _logical_capacity:
			_grow_logical_storage(maxi(MIN_LOGICAL_GROWTH, _logical_capacity * 2))
		slot = _logical_slot_count
		_logical_slot_count += 1
	var generation := int(_slot_generations[slot]) + 1
	if generation > MAX_GENERATION:
		generation = 1
	_slot_generations[slot] = generation
	_slot_states[slot] = 1
	_families[slot] = family
	_owner_ids[slot] = owner_id
	_target_ids[slot] = target_id
	_positions_a[slot] = Vector2.ZERO
	_positions_b[slot] = Vector2.ZERO
	_progresses[slot] = 0.0
	_chain_radii[slot] = 0.0
	_live_count += 1
	_metric_acquisitions += 1
	return _encode_handle(slot)


func _grow_logical_storage(new_capacity: int) -> void:
	_slot_states.resize(new_capacity)
	_slot_generations.resize(new_capacity)
	_families.resize(new_capacity)
	_owner_ids.resize(new_capacity)
	_target_ids.resize(new_capacity)
	_positions_a.resize(new_capacity)
	_positions_b.resize(new_capacity)
	_progresses.resize(new_capacity)
	_chain_radii.resize(new_capacity)
	_free_slots.resize(new_capacity)
	_logical_capacity = new_capacity


func _resolve_slot_for_family(handle: int, family: Family) -> int:
	var slot := _resolve_slot(handle)
	return slot if slot >= 0 and _families[slot] == family else INVALID_SLOT


func _resolve_slot(handle: int) -> int:
	if handle <= 0:
		return INVALID_SLOT
	var slot := int(handle & HANDLE_SLOT_MASK) - 1
	var generation := int(handle >> HANDLE_SLOT_BITS)
	if (
		slot < 0
		or slot >= _logical_slot_count
		or generation <= 0
		or _slot_states[slot] == 0
		or _slot_generations[slot] != generation
	):
		return INVALID_SLOT
	return slot


func _encode_handle(slot: int) -> int:
	return (int(_slot_generations[slot]) << HANDLE_SLOT_BITS) | (slot + 1)


func clear() -> void:
	for slot in range(_logical_slot_count):
		_slot_states[slot] = 0
		_families[slot] = Family.INVALID
	_free_slot_count = 0
	_logical_slot_count = 0
	_live_count = 0
	_reticle_winners.clear()
	_clear_visible_prefixes()


func prepare_for_runtime_teardown() -> void:
	if _teardown_prepared:
		return
	_teardown_prepared = true
	_teardown_count += 1
	clear()
	_combat_runtime = null
	_enemy_simulation_coordinator = null
	_disable_visual_storage()


func get_metrics() -> Dictionary:
	return {
		"bound": is_bound(),
		"headless_disabled": _headless_disabled,
		"teardown_prepared": _teardown_prepared,
		"teardown_count": _teardown_count,
		"live_warnings": _live_count,
		"logical_slot_count": _logical_slot_count,
		"logical_capacity": _logical_capacity,
		"lightning_visual_capacity": LIGHTNING_VISUAL_CAPACITY,
		"sniper_line_visual_capacity": SNIPER_LINE_VISUAL_CAPACITY,
		"sniper_reticle_visual_capacity": SNIPER_RETICLE_VISUAL_CAPACITY,
		"visible_lightning": _last_lightning_visible,
		"visible_sniper_lines": _last_line_visible,
		"visible_sniper_reticles": _last_reticle_visible,
		"last_lightning_capacity_drops": _last_lightning_drops,
		"last_line_capacity_drops": _last_line_drops,
		"last_reticle_capacity_drops": _last_reticle_drops,
		"acquisitions": _metric_acquisitions,
		"acquisition_rejections": _metric_acquisition_rejections,
		"updates": _metric_updates,
		"update_rejections": _metric_update_rejections,
		"releases": _metric_releases,
		"flushes": _metric_flushes,
		"visual_writes": _metric_visual_writes,
		"headless_flush_skips": _metric_headless_flush_skips,
		"reticle_arbitrations": _metric_reticle_arbitrations,
		"reticle_losers": _metric_reticle_losers,
		"allocated_lightning_instances": _instance_count(_get_lightning_multimesh()),
		"allocated_sniper_line_instances": _instance_count(_get_line_multimesh()),
		"allocated_sniper_reticle_instances": _instance_count(_get_reticle_multimesh()),
	}


func _reset_last_flush_metrics() -> void:
	_last_lightning_visible = 0
	_last_line_visible = 0
	_last_reticle_visible = 0
	_last_lightning_drops = 0
	_last_line_drops = 0
	_last_reticle_drops = 0


func _clear_visible_prefixes() -> void:
	var lightning := _get_lightning_multimesh()
	var lines := _get_line_multimesh()
	var reticles := _get_reticle_multimesh()
	if lightning != null:
		lightning.visible_instance_count = 0
	if lines != null:
		lines.visible_instance_count = 0
	if reticles != null:
		reticles.visible_instance_count = 0
	_reset_last_flush_metrics()


func _disable_visual_storage() -> void:
	for multimesh in [_get_lightning_multimesh(), _get_line_multimesh(), _get_reticle_multimesh()]:
		if multimesh != null:
			multimesh.visible_instance_count = 0
			multimesh.instance_count = 0


func _get_lightning_multimesh() -> MultiMesh:
	var node := get_node_or_null("LightningWarnings") as MultiMeshInstance2D
	return node.multimesh if node != null else null


func _get_line_multimesh() -> MultiMesh:
	var node := get_node_or_null("SniperLines") as MultiMeshInstance2D
	return node.multimesh if node != null else null


func _get_reticle_multimesh() -> MultiMesh:
	var node := get_node_or_null("SniperReticles") as MultiMeshInstance2D
	return node.multimesh if node != null else null


static func _is_valid_authored_multimesh(multimesh: MultiMesh) -> bool:
	return (
		multimesh != null
		and multimesh.transform_format == MultiMesh.TRANSFORM_2D
		and multimesh.use_custom_data
		and multimesh.mesh != null
	)


static func _instance_count(multimesh: MultiMesh) -> int:
	return multimesh.instance_count if multimesh != null else 0


static func _is_headless_display() -> bool:
	return DisplayServer.get_name() == "headless"


func _exit_tree() -> void:
	prepare_for_runtime_teardown()
