extends Node
class_name GuardianAuraSystem

## 守卫光环不再依赖每只守卫的 Area2D 持续生成物理重叠对。
## 本节点在敌人完成物理移动后，让少量守卫低频查询 CombatTargetIndex 的局部候选，
## 再以精确几何和双向来源表差分维护防御修正；旧的目标驱动粗网格保留作严格 A/B。
## 物理追帧期间同一可见帧只执行一次服务步，避免低帧率反过来放大光环查询负载。

const ENEMY_COLLISION_LAYER := 4
const REFRESH_TIME_CHECK_INTERVAL := 8
const SOURCE_REFRESH_TIME_CHECK_INTERVAL := 1
const SOURCE_CANDIDATE_TIME_CHECK_INTERVAL := 8

# Production refreshes outward from the much smaller guardian-source cohort.
# Tests and performance probes can flip this strict process-wide switch to run
# the former target-driven implementation against the exact same live nodes.
static var source_driven_refresh_enabled := true
static var unchanged_source_diff_fast_path_enabled := true

@export var enemy_container_path := NodePath("../EnemyContainer")
@export var target_container_paths: Array[NodePath] = [
	NodePath("../EnemyContainer"),
	NodePath("../BossContainer"),
]
@export_range(16.0, 256.0, 1.0, "or_greater") var grid_cell_size := 64.0
@export_range(0.02, 0.5, 0.01, "or_greater") var refresh_interval_seconds := 0.2
# Keep the fixed-physics ordering, but shed duplicate catch-up ticks that belong
# to the same rendered frame. Source removal remains synchronous through signals.
@export var limit_refresh_to_once_per_render_frame := true
@export_range(1, 512, 1, "or_greater") var max_refresh_targets_per_render_frame := 100
@export_range(1, 128, 1, "or_greater") var max_refresh_guardians_per_render_frame := 32
@export_range(250, 10000, 50, "or_greater") var max_refresh_service_usec := 2500
# Strict in-process A/B switch. Production uses the compact snapshot whose
# buckets cover the guardian aura AABB; the legacy branch remains available to
# prove identical source membership against the former center-cell search.
@export var use_snapshot_coverage_grid := true
# The enemy collision cache already owns a conservative circle around every
# authored body shape. Two circle certificates can therefore prove most overlap
# pairs without touching CollisionShape2D transforms; only the narrow boundary
# annulus falls back to the former exact shape tests.
@export var use_extent_overlap_certificates := true
# Isolated fixtures without a CombatTargetIndex may opt into the exact legacy
# scan. Production leaves this disabled: a temporarily incomplete index defers
# one refresh instead of turning a registration race into an O(enemy_count)
# visible-frame spike.
@export var allow_tracked_enemy_fallback_scan := false

var authoritative_processing_enabled := true
var enemy_container: Node = null
var target_containers: Array[Node] = []
var tracked_enemies: Dictionary[int, Enemy] = {}
var tracked_enemy_ids: Array[int] = []
var tracked_enemy_slot_by_id: Dictionary[int, int] = {}
var guardian_source_enemy_ids: Dictionary[int, bool] = {}
var pending_guardian_classification: Dictionary[int, bool] = {}
var guardians: Dictionary[int, Enemy] = {}
var guardian_ids: Array[int] = []
var guardian_slot_by_id: Dictionary[int, int] = {}

# enemy_id -> { guardian_instance_id: defense_bonus }
var aura_sources_by_enemy: Dictionary[int, Dictionary] = {}
# guardian_instance_id -> { enemy_id: true }
var covered_enemy_ids_by_guardian: Dictionary[int, Dictionary] = {}
var applied_defense_bonus_by_guardian: Dictionary[int, int] = {}
var guardian_grid: Dictionary[Vector2i, Array] = {}
# Active guardian data is resolved once at the start of an admitted service step. Grid
# buckets store these compact slots, so the target hot path does not repeat
# Node validity checks, config casts, transforms, or radius calculations for
# every guardian-target candidate pair.
var active_guardian_source_ids := PackedInt64Array()
var active_guardian_positions := PackedVector2Array()
var active_guardian_radii := PackedFloat64Array()
var active_guardian_bonuses := PackedInt32Array()
var candidate_seen_epoch_by_active_slot := PackedInt32Array()
var candidate_query_epoch := 0
var desired_sources_scratch: Dictionary[int, int] = {}
var current_source_ids_scratch: Array[int] = []
var desired_covered_enemy_ids_scratch: Dictionary[int, bool] = {}
var current_covered_enemy_ids_scratch: Array[int] = []
var source_candidate_scratch: Array[Enemy] = []
# Every production guardian is bound to the same authoritative combat index.
# Resolve and certify that index once per non-yielding service batch; individual
# sources still verify their own binding before consuming it.
var source_query_index_scope_active := false
var source_query_index: CombatTargetIndex = null
# A dense source can cross the per-frame deadline. Keep its one index result and
# partial membership set alive until the next render frame, then publish only
# after every candidate is processed; no repeated work or partial aura state.
var pending_source_refresh_id := 0
var pending_source_refresh_candidate_cursor := 0
var pending_source_refresh_position := Vector2.ZERO
var pending_source_refresh_world_radius := 0.0
var pending_source_refresh_defense_bonus := 0
var pending_source_candidates_require_revalidation := false
var maximum_guardian_radius := 0.0
var maximum_tracked_target_extent := 0.0
var refresh_cursor := 0
var refresh_target_debt := 0.0
var refresh_guardian_cursor := 0
var refresh_guardian_debt := 0.0
var last_refresh_render_frame := -1
var refresh_service_step_count := 0
var refresh_target_visit_count := 0
var refresh_budget_deferral_count := 0
var refresh_service_usec_total := 0
var maximum_refresh_service_usec := 0
var last_refresh_target_count := 0
var last_refresh_service_usec := 0
var source_refresh_count := 0
var source_candidate_visit_count := 0
var source_index_query_count := 0
var source_fallback_scan_count := 0
var source_deferred_refresh_count := 0
var source_unchanged_diff_skip_count := 0
var last_refresh_guardian_count := 0

# Disabled in production. Performance probes can count which exact-equivalent
# certificate handled each candidate without adding counters to the live hot path.
var collect_overlap_query_metrics := false
var overlap_candidate_count := 0
var overlap_fast_accept_count := 0
var overlap_fast_reject_count := 0
var overlap_exact_fallback_count := 0


func _ready() -> void:
	enemy_container = get_node_or_null(enemy_container_path)
	if enemy_container == null:
		push_error(
			"GuardianAuraSystem could not resolve EnemyContainer at %s."
			% enemy_container_path
		)
		set_physics_process(false)
		return
	if not authoritative_processing_enabled:
		set_physics_process(false)
		return

	var connected_container_ids: Dictionary[int, bool] = {}
	for target_container_path in target_container_paths:
		var target_container := get_node_or_null(target_container_path)
		if target_container == null:
			push_warning(
				"GuardianAuraSystem could not resolve target container at %s."
				% target_container_path
			)
			continue
		_connect_target_container(target_container, connected_container_ids)
	# 来源容器也是必需的目标容器，即使 authored 列表被误删也保持此不变量。
	_connect_target_container(enemy_container, connected_container_ids)
	set_physics_process(true)


func set_authoritative_processing_enabled(enabled: bool) -> void:
	authoritative_processing_enabled = enabled
	set_physics_process(enabled and enemy_container != null)
	if not is_node_ready():
		return
	if not enabled:
		for enemy_id_variant in tracked_enemy_ids.duplicate():
			_untrack_enemy_id(int(enemy_id_variant))
		_clear_pending_source_refresh()
		refresh_cursor = 0
		refresh_target_debt = 0.0
		refresh_guardian_cursor = 0
		refresh_guardian_debt = 0.0
		return
	for target_container in target_containers:
		if target_container == null or not is_instance_valid(target_container):
			continue
		var is_guardian_source_container := target_container == enemy_container
		for child in target_container.get_children():
			_track_enemy(child as Enemy, is_guardian_source_container)


func _exit_tree() -> void:
	_clear_all_guardian_sources()
	target_containers.clear()
	tracked_enemies.clear()
	tracked_enemy_ids.clear()
	tracked_enemy_slot_by_id.clear()
	guardian_source_enemy_ids.clear()
	pending_guardian_classification.clear()
	guardians.clear()
	guardian_ids.clear()
	guardian_slot_by_id.clear()
	guardian_grid.clear()
	applied_defense_bonus_by_guardian.clear()
	active_guardian_source_ids.clear()
	active_guardian_positions.clear()
	active_guardian_radii.clear()
	active_guardian_bonuses.clear()
	candidate_seen_epoch_by_active_slot.clear()
	candidate_query_epoch = 0
	desired_sources_scratch.clear()
	current_source_ids_scratch.clear()
	desired_covered_enemy_ids_scratch.clear()
	current_covered_enemy_ids_scratch.clear()
	source_candidate_scratch.clear()
	_end_source_query_index_scope()
	_clear_pending_source_refresh()
	maximum_tracked_target_extent = 0.0


func _physics_process(delta: float) -> void:
	if not authoritative_processing_enabled:
		return
	_accumulate_refresh_debt(delta)
	if limit_refresh_to_once_per_render_frame:
		var render_frame := Engine.get_process_frames()
		if render_frame == last_refresh_render_frame:
			return
		last_refresh_render_frame = render_frame
	_service_refresh_target_debt()


func _run_refresh_service_step(delta: float) -> void:
	_accumulate_refresh_debt(delta)
	_service_refresh_target_debt()


func _service_refresh_target_debt() -> void:
	refresh_service_step_count += 1
	last_refresh_target_count = 0
	last_refresh_guardian_count = 0
	last_refresh_service_usec = 0
	_classify_pending_guardians()
	if source_driven_refresh_enabled:
		_service_source_driven_refresh()
		return
	if guardian_ids.is_empty() and aura_sources_by_enemy.is_empty():
		# Waves without guardians have no source membership to maintain. Clear the
		# coalesced scheduler debt at the system boundary instead of visiting every
		# enemy at 10 Hz only to rediscover the same empty set.
		refresh_cursor = 0
		refresh_target_debt = 0.0
		return
	var enemy_count := tracked_enemy_ids.size()
	if enemy_count <= 0:
		refresh_cursor = 0
		refresh_target_debt = 0.0
		return
	var batch_size := mini(
		floori(refresh_target_debt + 0.0001),
		mini(enemy_count, max_refresh_targets_per_render_frame)
	)
	if batch_size <= 0:
		return

	var started_usec := Time.get_ticks_usec()
	_rebuild_guardian_grid()
	var processed_count := _process_refresh_batch(
		batch_size,
		started_usec + max_refresh_service_usec
	)
	last_refresh_target_count = processed_count
	refresh_target_visit_count += processed_count
	refresh_target_debt = clampf(
		refresh_target_debt - float(processed_count),
		0.0,
		float(tracked_enemy_ids.size())
	)
	last_refresh_service_usec = int(Time.get_ticks_usec() - started_usec)
	refresh_service_usec_total += last_refresh_service_usec
	maximum_refresh_service_usec = maxi(
		maximum_refresh_service_usec,
		last_refresh_service_usec
	)
	if refresh_target_debt >= 1.0:
		refresh_budget_deferral_count += 1


func _service_source_driven_refresh() -> void:
	if guardian_ids.is_empty():
		refresh_guardian_cursor = 0
		refresh_guardian_debt = 0.0
		# Defeat/container signals normally remove every source in the same call
		# stack. This only repairs an abnormal missed lifecycle notification.
		if not covered_enemy_ids_by_guardian.is_empty():
			for source_id_variant in covered_enemy_ids_by_guardian.keys():
				_remove_guardian_source(int(source_id_variant))
		return
	var guardian_count := guardian_ids.size()
	var batch_size := mini(
		floori(refresh_guardian_debt + 0.0001),
		mini(guardian_count, max_refresh_guardians_per_render_frame)
	)
	if batch_size <= 0:
		return

	var started_usec := Time.get_ticks_usec()
	_begin_source_query_index_scope()
	var processed_count := _process_source_refresh_batch(
		batch_size,
		started_usec + max_refresh_service_usec
	)
	_end_source_query_index_scope()
	last_refresh_guardian_count = processed_count
	source_refresh_count += processed_count
	refresh_guardian_debt = clampf(
		refresh_guardian_debt - float(processed_count),
		0.0,
		float(guardian_ids.size())
	)
	last_refresh_service_usec = int(Time.get_ticks_usec() - started_usec)
	refresh_service_usec_total += last_refresh_service_usec
	maximum_refresh_service_usec = maxi(
		maximum_refresh_service_usec,
		last_refresh_service_usec
	)
	if refresh_guardian_debt >= 1.0:
		refresh_budget_deferral_count += 1


func _process_source_refresh_batch(batch_size: int, deadline_usec: int) -> int:
	var processed_count := 0
	for batch_index in range(batch_size):
		if (
			batch_index > 0
			and batch_index % SOURCE_REFRESH_TIME_CHECK_INTERVAL == 0
			and Time.get_ticks_usec() >= deadline_usec
		):
			break
		if guardian_ids.is_empty():
			refresh_guardian_cursor = 0
			break
		if refresh_guardian_cursor >= guardian_ids.size():
			refresh_guardian_cursor = 0
		var source_id := guardian_ids[refresh_guardian_cursor]
		var guardian := guardians.get(source_id) as Enemy
		if guardian == null or not is_instance_valid(guardian) or guardian.is_dead:
			if tracked_enemies.has(source_id):
				_untrack_enemy_id(source_id)
			else:
				_remove_guardian_source(source_id)
			continue
		if not _refresh_guardian_coverage(guardian, deadline_usec):
			source_deferred_refresh_count += 1
			break
		refresh_guardian_cursor += 1
		processed_count += 1
	return processed_count


func _accumulate_refresh_debt(delta: float) -> void:
	if source_driven_refresh_enabled:
		_accumulate_refresh_guardian_debt(delta)
	else:
		_accumulate_refresh_target_debt(delta)


func _accumulate_refresh_target_debt(delta: float) -> void:
	var enemy_count := tracked_enemy_ids.size()
	if enemy_count <= 0:
		refresh_target_debt = 0.0
		return
	if delta <= 0.0:
		return
	# Multiple missed passes over the same target collapse into one latest-state
	# refresh. This preserves useful debt while preventing an unbounded catch-up
	# queue after a long visible frame or a throttled window.
	refresh_target_debt = minf(
		float(enemy_count),
		refresh_target_debt
		+ float(enemy_count) * delta / maxf(refresh_interval_seconds, 0.0001)
	)


func _accumulate_refresh_guardian_debt(delta: float) -> void:
	var guardian_count := guardian_ids.size()
	if guardian_count <= 0:
		refresh_guardian_debt = 0.0
		return
	if delta <= 0.0:
		return
	# As with the legacy target scheduler, missed passes collapse into the latest
	# state. Each source is therefore queried at most once after a long stall.
	refresh_guardian_debt = minf(
		float(guardian_count),
		refresh_guardian_debt
		+ float(guardian_count) * delta / maxf(refresh_interval_seconds, 0.0001)
	)


func _connect_target_container(
	target_container: Node,
	connected_container_ids: Dictionary[int, bool]
) -> void:
	var container_id := target_container.get_instance_id()
	if connected_container_ids.has(container_id):
		return
	connected_container_ids[container_id] = true
	target_containers.append(target_container)
	var entered_callback := _on_target_container_child_entered.bind(target_container)
	var exiting_callback := _on_target_container_child_exiting.bind(target_container)
	target_container.child_entered_tree.connect(entered_callback)
	target_container.child_exiting_tree.connect(exiting_callback)
	var is_guardian_source_container := target_container == enemy_container
	for child in target_container.get_children():
		_track_enemy(child as Enemy, is_guardian_source_container)


func _on_target_container_child_entered(child: Node, target_container: Node) -> void:
	if not authoritative_processing_enabled:
		return
	_track_enemy(child as Enemy, target_container == enemy_container)


func _on_target_container_child_exiting(child: Node, _target_container: Node) -> void:
	if not authoritative_processing_enabled:
		return
	var enemy := child as Enemy
	if enemy != null:
		_untrack_enemy_id(enemy.get_instance_id())


func _on_enemy_defeated(enemy: Enemy) -> void:
	if enemy != null:
		# defeated 在 Enemy 标记死亡的同一调用栈发出，因此来源不会多保留一帧。
		_untrack_enemy_id(enemy.get_instance_id())


func _on_guardian_aura_deactivated(guardian: Enemy) -> void:
	if guardian == null:
		return
	var source_id := guardian.get_instance_id()
	if guardians.has(source_id):
		_remove_guardian_source(source_id)


func _track_enemy(enemy: Enemy, can_be_guardian_source: bool) -> void:
	if not authoritative_processing_enabled or enemy == null:
		return
	var enemy_id := enemy.get_instance_id()
	if tracked_enemies.has(enemy_id):
		if can_be_guardian_source and not guardian_source_enemy_ids.has(enemy_id):
			guardian_source_enemy_ids[enemy_id] = true
			pending_guardian_classification[enemy_id] = true
		return
	tracked_enemies[enemy_id] = enemy
	tracked_enemy_slot_by_id[enemy_id] = tracked_enemy_ids.size()
	tracked_enemy_ids.append(enemy_id)
	maximum_tracked_target_extent = maxf(
		maximum_tracked_target_extent,
		_get_enemy_broadphase_extent(enemy)
	)
	if not enemy.is_node_ready():
		var ready_callback := _on_tracked_enemy_ready.bind(enemy_id)
		if not enemy.ready.is_connected(ready_callback):
			enemy.ready.connect(ready_callback, CONNECT_ONE_SHOT)
	if can_be_guardian_source:
		guardian_source_enemy_ids[enemy_id] = true
		pending_guardian_classification[enemy_id] = true
	if not enemy.defeated.is_connected(_on_enemy_defeated):
		enemy.defeated.connect(_on_enemy_defeated)
	var aura_enemy := enemy as YuanshiInsectAura
	if (
		aura_enemy != null
		and not aura_enemy.guardian_aura_deactivated.is_connected(
			_on_guardian_aura_deactivated
		)
	):
		aura_enemy.guardian_aura_deactivated.connect(_on_guardian_aura_deactivated)


func _on_tracked_enemy_ready(enemy_id: int) -> void:
	var enemy := tracked_enemies.get(enemy_id) as Enemy
	if enemy == null or not is_instance_valid(enemy) or enemy.is_dead:
		return
	# child_entered_tree precedes Enemy._ready(), where the collision profile is
	# built. Publish the real conservative radius before the first fixed-step
	# source query can exclude a boundary overlap.
	maximum_tracked_target_extent = maxf(
		maximum_tracked_target_extent,
		_get_enemy_broadphase_extent(enemy)
	)


func _classify_pending_guardians() -> void:
	if pending_guardian_classification.is_empty():
		return
	for enemy_id_variant in pending_guardian_classification.keys():
		var enemy_id := int(enemy_id_variant)
		if not guardian_source_enemy_ids.has(enemy_id):
			pending_guardian_classification.erase(enemy_id)
			continue
		var enemy := tracked_enemies.get(enemy_id) as Enemy
		if enemy == null or not is_instance_valid(enemy) or enemy.is_dead:
			pending_guardian_classification.erase(enemy_id)
			continue
		if enemy.config == null:
			continue
		pending_guardian_classification.erase(enemy_id)
		if enemy.config is YuanshiInsectGuardianConfig:
			guardians[enemy_id] = enemy
			guardian_slot_by_id[enemy_id] = guardian_ids.size()
			guardian_ids.append(enemy_id)


func _prune_dead_or_invalid_enemies() -> void:
	for index in range(tracked_enemy_ids.size() - 1, -1, -1):
		var enemy_id := tracked_enemy_ids[index]
		var enemy := tracked_enemies.get(enemy_id) as Enemy
		if enemy != null and is_instance_valid(enemy) and not enemy.is_dead:
			continue
		_untrack_enemy_id(enemy_id)


func _untrack_enemy_id(enemy_id: int) -> void:
	if not tracked_enemies.has(enemy_id):
		return

	var enemy := tracked_enemies.get(enemy_id) as Enemy
	if guardians.has(enemy_id):
		_remove_guardian_source(enemy_id)

	var incoming_sources: Dictionary = aura_sources_by_enemy.get(enemy_id, {})
	for source_id_variant in incoming_sources.keys():
		var source_id := int(source_id_variant)
		if enemy != null and is_instance_valid(enemy):
			enemy.remove_physical_defense_modifier(source_id)
		var covered_enemy_ids: Dictionary = covered_enemy_ids_by_guardian.get(source_id, {})
		covered_enemy_ids.erase(enemy_id)
		if covered_enemy_ids.is_empty():
			covered_enemy_ids_by_guardian.erase(source_id)
		else:
			covered_enemy_ids_by_guardian[source_id] = covered_enemy_ids
	aura_sources_by_enemy.erase(enemy_id)

	tracked_enemies.erase(enemy_id)
	guardian_source_enemy_ids.erase(enemy_id)
	pending_guardian_classification.erase(enemy_id)
	_remove_tracked_enemy_id(enemy_id)
	if tracked_enemy_ids.is_empty() or refresh_cursor >= tracked_enemy_ids.size():
		refresh_cursor = 0
	if tracked_enemy_ids.is_empty():
		maximum_tracked_target_extent = 0.0


func _remove_guardian_source(source_id: int) -> void:
	if pending_source_refresh_id == source_id:
		_clear_pending_source_refresh()
	var covered_enemy_ids: Dictionary = covered_enemy_ids_by_guardian.get(source_id, {})
	for enemy_id_variant in covered_enemy_ids.keys():
		var enemy_id := int(enemy_id_variant)
		var enemy := tracked_enemies.get(enemy_id) as Enemy
		if enemy != null and is_instance_valid(enemy):
			enemy.remove_physical_defense_modifier(source_id)
		var incoming_sources: Dictionary = aura_sources_by_enemy.get(enemy_id, {})
		incoming_sources.erase(source_id)
		if incoming_sources.is_empty():
			aura_sources_by_enemy.erase(enemy_id)
		else:
			aura_sources_by_enemy[enemy_id] = incoming_sources
	covered_enemy_ids_by_guardian.erase(source_id)
	applied_defense_bonus_by_guardian.erase(source_id)
	guardians.erase(source_id)
	_remove_guardian_id(source_id)


func _clear_all_guardian_sources() -> void:
	for source_id_variant in guardian_ids.duplicate():
		_remove_guardian_source(int(source_id_variant))


func _rebuild_guardian_grid() -> void:
	guardian_grid.clear()
	maximum_guardian_radius = 0.0
	active_guardian_source_ids.clear()
	active_guardian_positions.clear()
	active_guardian_radii.clear()
	active_guardian_bonuses.clear()
	if use_snapshot_coverage_grid:
		_rebuild_guardian_snapshot_coverage_grid()
		candidate_seen_epoch_by_active_slot.resize(active_guardian_source_ids.size())
		candidate_seen_epoch_by_active_slot.fill(0)
		candidate_query_epoch = 0
		return

	# Legacy A/B path: one guardian center per grid bucket, followed by a square
	# neighborhood search for every target.
	for source_id in guardian_ids:
		var guardian := guardians.get(source_id) as Enemy
		if guardian == null or not is_instance_valid(guardian) or guardian.is_dead:
			continue
		var guardian_config := guardian.config as YuanshiInsectGuardianConfig
		if guardian_config == null or not guardian_config.aura_enabled:
			continue
		if guardian_config.aura_physical_defense_bonus == 0:
			continue

		var world_radius := _get_guardian_world_radius(guardian, guardian_config)
		if world_radius <= 0.0:
			continue
		maximum_guardian_radius = maxf(maximum_guardian_radius, world_radius)
		var cell := _world_to_cell(guardian.global_position)
		if guardian_grid.has(cell):
			var bucket: Array = guardian_grid[cell]
			bucket.append(source_id)
		else:
			guardian_grid[cell] = [source_id]


func _rebuild_guardian_snapshot_coverage_grid() -> void:
	for source_id in guardian_ids:
		var guardian := guardians.get(source_id) as Enemy
		if guardian == null or not is_instance_valid(guardian) or guardian.is_dead:
			continue
		var guardian_config := guardian.config as YuanshiInsectGuardianConfig
		if guardian_config == null or not guardian_config.aura_enabled:
			continue
		var defense_bonus := guardian_config.aura_physical_defense_bonus
		if defense_bonus == 0:
			continue

		var world_radius := _get_guardian_world_radius(guardian, guardian_config)
		if world_radius <= 0.0:
			continue
		var active_slot := active_guardian_source_ids.size()
		var aura_center := guardian.global_position
		active_guardian_source_ids.append(source_id)
		active_guardian_positions.append(aura_center)
		active_guardian_radii.append(world_radius)
		active_guardian_bonuses.append(defense_bonus)

		# Stamp every grid cell touched by the aura AABB. A target queries every
		# cell touched by its conservative body AABB; any real circle-shape
		# intersection therefore shares at least one cell and cannot be missed.
		var extent := Vector2.ONE * world_radius
		var minimum_cell := _world_to_cell(aura_center - extent)
		var maximum_cell := _world_to_cell(aura_center + extent)
		for cell_y in range(minimum_cell.y, maximum_cell.y + 1):
			for cell_x in range(minimum_cell.x, maximum_cell.x + 1):
				var cell := Vector2i(cell_x, cell_y)
				var bucket_variant: Variant = guardian_grid.get(cell)
				if bucket_variant != null:
					var bucket := bucket_variant as Array
					bucket.append(active_slot)
				else:
					guardian_grid[cell] = [active_slot]


func _process_refresh_batch(batch_size: int, deadline_usec: int) -> int:
	var processed_count := 0
	for batch_index in range(batch_size):
		if (
			processed_count > 0
			and batch_index % REFRESH_TIME_CHECK_INTERVAL == 0
			and Time.get_ticks_usec() >= deadline_usec
		):
			break
		if tracked_enemy_ids.is_empty():
			refresh_cursor = 0
			break
		if refresh_cursor >= tracked_enemy_ids.size():
			refresh_cursor = 0
		var enemy_id := tracked_enemy_ids[refresh_cursor]
		refresh_cursor += 1
		processed_count += 1
		var enemy := tracked_enemies.get(enemy_id) as Enemy
		if enemy == null or not is_instance_valid(enemy) or enemy.is_dead:
			# Normal defeat and container removal are synchronous. This bounded audit
			# is the safety net for an abnormal missed signal, folded into the same
			# cursor that already visits every target once per refresh interval.
			_untrack_enemy_id(enemy_id)
			continue
		_refresh_enemy_sources(enemy)
	return processed_count


func _refresh_guardian_coverage(
	guardian: Enemy,
	deadline_usec: int = 0
) -> bool:
	var source_id := guardian.get_instance_id()
	var guardian_config := guardian.config as YuanshiInsectGuardianConfig
	if (
		guardian_config == null
		or not guardian_config.aura_enabled
		or guardian_config.aura_physical_defense_bonus == 0
	):
		_clear_pending_source_refresh()
		_apply_guardian_coverage_diff(
			source_id,
			0,
			desired_covered_enemy_ids_scratch
		)
		return true
	var world_radius := _get_guardian_world_radius(guardian, guardian_config)
	if world_radius <= 0.0:
		_clear_pending_source_refresh()
		_apply_guardian_coverage_diff(
			source_id,
			0,
			desired_covered_enemy_ids_scratch
		)
		return true

	if pending_source_refresh_id != source_id:
		_clear_pending_source_refresh()
		if not _collect_source_query_candidates(guardian, world_radius):
			return false
		pending_source_refresh_id = source_id
		pending_source_refresh_position = guardian.global_position
		pending_source_refresh_world_radius = world_radius
		pending_source_refresh_defense_bonus = (
			guardian_config.aura_physical_defense_bonus
		)

	var chunk_start := pending_source_refresh_candidate_cursor
	for candidate_index in range(
		chunk_start,
		source_candidate_scratch.size()
	):
		if (
			deadline_usec > 0
			and (
				candidate_index - chunk_start
			) % SOURCE_CANDIDATE_TIME_CHECK_INTERVAL == 0
			and Time.get_ticks_usec() >= deadline_usec
		):
			source_candidate_visit_count += candidate_index - chunk_start
			pending_source_refresh_candidate_cursor = candidate_index
			pending_source_candidates_require_revalidation = true
			return false
		var enemy := source_candidate_scratch[candidate_index]
		# CombatTargetIndex already returned a live, finite candidate in this same
		# synchronous call stack. Only a snapshot retained past the service deadline
		# can become stale before consumption, so keep the costly Object checks on
		# that cross-frame path instead of repeating them for every ordinary hit.
		if (
			(
				pending_source_candidates_require_revalidation
				and (
					enemy == null
					or not is_instance_valid(enemy)
					or enemy.is_dead
					or enemy.is_queued_for_deletion()
				)
			)
			or enemy == guardian
			or (enemy.collision_layer & ENEMY_COLLISION_LAYER) == 0
			or not _has_enabled_body_collision_shape(enemy)
		):
			continue
		var enemy_id := enemy.get_instance_id()
		if not tracked_enemies.has(enemy_id):
			continue
		var target_center := enemy.global_position
		var target_extent := _get_enemy_broadphase_extent(enemy)
		# Collision extents are authored once for current enemies. Keep the
		# high-water mark conservative if a candidate is ever enlarged.
		maximum_tracked_target_extent = maxf(
			maximum_tracked_target_extent,
			target_extent
		)
		if _guardian_circle_reaches_enemy(
			pending_source_refresh_position,
			pending_source_refresh_world_radius,
			enemy,
			target_center,
			target_extent
		):
			desired_covered_enemy_ids_scratch[enemy_id] = true
	source_candidate_visit_count += (
		source_candidate_scratch.size() - chunk_start
	)
	_apply_guardian_coverage_diff(
		source_id,
		pending_source_refresh_defense_bonus,
		desired_covered_enemy_ids_scratch
	)
	_clear_pending_source_refresh()
	return true


func _clear_pending_source_refresh() -> void:
	pending_source_refresh_id = 0
	pending_source_refresh_candidate_cursor = 0
	pending_source_refresh_position = Vector2.ZERO
	pending_source_refresh_world_radius = 0.0
	pending_source_refresh_defense_bonus = 0
	pending_source_candidates_require_revalidation = false
	source_candidate_scratch.clear()
	desired_covered_enemy_ids_scratch.clear()


func _collect_source_query_candidates(
	guardian: Enemy,
	world_radius: float
) -> bool:
	source_candidate_scratch.clear()
	var target_index: CombatTargetIndex = null
	if source_query_index_scope_active:
		if (
			source_query_index != null
			and guardian.combat_target_index_binding == source_query_index
			and guardian.combat_target_index_net_id > 0
		):
			target_index = source_query_index
	else:
		target_index = _get_complete_combat_target_index(guardian)
	if target_index != null:
		target_index.query_radius_unordered_into(
			guardian.global_position,
			world_radius + maximum_tracked_target_extent,
			source_candidate_scratch
		)
		source_index_query_count += 1
		return true

	if not allow_tracked_enemy_fallback_scan:
		return false
	# Explicit unit fixtures without CombatRuntimeBase or network IDs can retain
	# exact legacy behavior. This branch is never enabled by production scenes.
	source_fallback_scan_count += 1
	for enemy_id in tracked_enemy_ids:
		var enemy := tracked_enemies.get(enemy_id) as Enemy
		if enemy != null and is_instance_valid(enemy) and not enemy.is_dead:
			source_candidate_scratch.append(enemy)
	return true


func _begin_source_query_index_scope() -> void:
	source_query_index_scope_active = true
	source_query_index = null
	for source_id in guardian_ids:
		var guardian := guardians.get(source_id) as Enemy
		if guardian == null or not is_instance_valid(guardian) or guardian.is_dead:
			continue
		source_query_index = _get_complete_combat_target_index(guardian)
		return


func _end_source_query_index_scope() -> void:
	source_query_index_scope_active = false
	source_query_index = null


func _get_complete_combat_target_index(guardian: Enemy) -> CombatTargetIndex:
	var target_index := guardian.combat_target_index_binding
	if (
		target_index == null
		or guardian.combat_target_index_net_id <= 0
		or target_index.enemies_by_net_id.size() != tracked_enemy_ids.size()
	):
		return null
	if (
		target_index.get_enemy(guardian.combat_target_index_net_id)
		!= guardian
	):
		return null
	return target_index


func _apply_guardian_coverage_diff(
	source_id: int,
	defense_bonus: int,
	desired_enemy_ids: Dictionary
) -> void:
	var current_enemy_ids: Dictionary = covered_enemy_ids_by_guardian.get(
		source_id,
		{}
	)
	if (
		GuardianAuraSystem.unchanged_source_diff_fast_path_enabled
		and int(applied_defense_bonus_by_guardian.get(source_id, 0))
			== defense_bonus
		and current_enemy_ids.size() == desired_enemy_ids.size()
	):
		var coverage_unchanged := true
		for desired_enemy_id_variant in desired_enemy_ids:
			if not current_enemy_ids.has(int(desired_enemy_id_variant)):
				coverage_unchanged = false
				break
		if coverage_unchanged:
			source_unchanged_diff_skip_count += 1
			return
	current_covered_enemy_ids_scratch.clear()
	for enemy_id_variant in current_enemy_ids:
		current_covered_enemy_ids_scratch.append(int(enemy_id_variant))
	for enemy_id in current_covered_enemy_ids_scratch:
		if desired_enemy_ids.has(enemy_id):
			continue
		var enemy := tracked_enemies.get(enemy_id) as Enemy
		if enemy != null and is_instance_valid(enemy):
			enemy.remove_physical_defense_modifier(source_id)
		var incoming_sources: Dictionary = aura_sources_by_enemy.get(enemy_id, {})
		incoming_sources.erase(source_id)
		if incoming_sources.is_empty():
			aura_sources_by_enemy.erase(enemy_id)
		else:
			aura_sources_by_enemy[enemy_id] = incoming_sources
		current_enemy_ids.erase(enemy_id)

	for enemy_id_variant in desired_enemy_ids:
		var enemy_id := int(enemy_id_variant)
		var enemy := tracked_enemies.get(enemy_id) as Enemy
		if enemy == null or not is_instance_valid(enemy) or enemy.is_dead:
			continue
		var incoming_sources: Dictionary = aura_sources_by_enemy.get(enemy_id, {})
		if int(incoming_sources.get(source_id, 0)) != defense_bonus:
			enemy.add_physical_defense_modifier(source_id, defense_bonus)
			incoming_sources[source_id] = defense_bonus
			aura_sources_by_enemy[enemy_id] = incoming_sources
		current_enemy_ids[enemy_id] = true

	if current_enemy_ids.is_empty():
		covered_enemy_ids_by_guardian.erase(source_id)
		applied_defense_bonus_by_guardian.erase(source_id)
	else:
		covered_enemy_ids_by_guardian[source_id] = current_enemy_ids
		applied_defense_bonus_by_guardian[source_id] = defense_bonus


func _refresh_enemy_sources(enemy: Enemy) -> void:
	var enemy_id := enemy.get_instance_id()
	# Refreshes are synchronous and processed one enemy at a time, so one reused
	# dictionary removes a short-lived allocation from every aura target refresh.
	desired_sources_scratch.clear()
	var has_current_sources := aura_sources_by_enemy.has(enemy_id)
	if (
		(enemy.collision_layer & ENEMY_COLLISION_LAYER) == 0
		or guardian_grid.is_empty()
		or not _has_enabled_body_collision_shape(enemy)
	):
		if has_current_sources:
			_apply_source_diff(enemy, desired_sources_scratch)
		return

	var target_center := enemy.global_position
	var target_extent := _get_enemy_broadphase_extent(enemy)
	if use_snapshot_coverage_grid:
		_collect_snapshot_guardian_sources(
			enemy,
			enemy_id,
			target_center,
			target_extent
		)
	else:
		_collect_legacy_guardian_sources(
			enemy,
			enemy_id,
			target_center,
			target_extent
		)

	if desired_sources_scratch.is_empty() and not has_current_sources:
		return
	_apply_source_diff(enemy, desired_sources_scratch)


func _collect_snapshot_guardian_sources(
	enemy: Enemy,
	enemy_id: int,
	target_center: Vector2,
	target_extent: float
) -> void:
	var extent := Vector2.ONE * target_extent
	var minimum_cell := _world_to_cell(target_center - extent)
	var maximum_cell := _world_to_cell(target_center + extent)
	var query_epoch := _begin_candidate_query_epoch()
	for cell_y in range(minimum_cell.y, maximum_cell.y + 1):
		for cell_x in range(minimum_cell.x, maximum_cell.x + 1):
			var cell := Vector2i(cell_x, cell_y)
			var active_slots_variant: Variant = guardian_grid.get(cell)
			if active_slots_variant == null:
				continue
			var active_slots := active_slots_variant as Array
			for active_slot_variant in active_slots:
				var active_slot := int(active_slot_variant)
				if candidate_seen_epoch_by_active_slot[active_slot] == query_epoch:
					continue
				candidate_seen_epoch_by_active_slot[active_slot] = query_epoch
				var source_id := int(active_guardian_source_ids[active_slot])
				if source_id == enemy_id:
					continue
				if _snapshot_guardian_reaches_enemy(
					active_slot,
					enemy,
					target_center,
					target_extent
				):
					desired_sources_scratch[source_id] = active_guardian_bonuses[active_slot]


func _collect_legacy_guardian_sources(
	enemy: Enemy,
	enemy_id: int,
	target_center: Vector2,
	target_extent: float
) -> void:
	var search_radius := maximum_guardian_radius + target_extent
	var cell_radius := ceili(search_radius / maxf(grid_cell_size, 1.0))
	var center_cell := _world_to_cell(target_center)
	for cell_y in range(center_cell.y - cell_radius, center_cell.y + cell_radius + 1):
		for cell_x in range(center_cell.x - cell_radius, center_cell.x + cell_radius + 1):
			var cell := Vector2i(cell_x, cell_y)
			if not guardian_grid.has(cell):
				continue
			var source_ids: Array = guardian_grid[cell]
			for source_id_variant in source_ids:
				var source_id := int(source_id_variant)
				if source_id == enemy_id:
					continue
				var guardian := guardians.get(source_id) as Enemy
				if guardian == null or not is_instance_valid(guardian) or guardian.is_dead:
					continue
				var guardian_config := guardian.config as YuanshiInsectGuardianConfig
				if guardian_config == null or not guardian_config.aura_enabled:
					continue
				if _guardian_reaches_enemy(
					guardian,
					guardian_config,
					enemy,
					target_center,
					target_extent
				):
					desired_sources_scratch[source_id] = (
						guardian_config.aura_physical_defense_bonus
					)


func _begin_candidate_query_epoch() -> int:
	if candidate_query_epoch >= 2147483647:
		candidate_seen_epoch_by_active_slot.fill(0)
		candidate_query_epoch = 1
	else:
		candidate_query_epoch += 1
	return candidate_query_epoch


func _apply_source_diff(enemy: Enemy, desired_sources: Dictionary) -> void:
	var enemy_id := enemy.get_instance_id()
	var current_sources: Dictionary = aura_sources_by_enemy.get(enemy_id, {})
	# Source removal must happen after Dictionary traversal. Reuse one typed array
	# instead of allocating `keys()` for every aura target refresh.
	current_source_ids_scratch.clear()
	for source_id_variant in current_sources:
		current_source_ids_scratch.append(int(source_id_variant))
	for source_id in current_source_ids_scratch:
		if desired_sources.has(source_id):
			continue
		enemy.remove_physical_defense_modifier(source_id)
		current_sources.erase(source_id)
		var covered_enemy_ids: Dictionary = covered_enemy_ids_by_guardian.get(source_id, {})
		covered_enemy_ids.erase(enemy_id)
		if covered_enemy_ids.is_empty():
			covered_enemy_ids_by_guardian.erase(source_id)
		else:
			covered_enemy_ids_by_guardian[source_id] = covered_enemy_ids

	for source_id_variant in desired_sources:
		var source_id := int(source_id_variant)
		var desired_bonus := int(desired_sources[source_id])
		if int(current_sources.get(source_id, 0)) == desired_bonus:
			continue
		enemy.add_physical_defense_modifier(source_id, desired_bonus)
		current_sources[source_id] = desired_bonus
		var covered_enemy_ids: Dictionary = covered_enemy_ids_by_guardian.get(source_id, {})
		covered_enemy_ids[enemy_id] = true
		covered_enemy_ids_by_guardian[source_id] = covered_enemy_ids

	if current_sources.is_empty():
		aura_sources_by_enemy.erase(enemy_id)
	else:
		aura_sources_by_enemy[enemy_id] = current_sources


func _guardian_reaches_enemy(
	guardian: Enemy,
	guardian_config: YuanshiInsectGuardianConfig,
	enemy: Enemy,
	target_center: Vector2,
	target_extent: float
) -> bool:
	return _guardian_circle_reaches_enemy(
		guardian.global_position,
		_get_guardian_world_radius(guardian, guardian_config),
		enemy,
		target_center,
		target_extent
	)


func _snapshot_guardian_reaches_enemy(
	active_slot: int,
	enemy: Enemy,
	target_center: Vector2,
	target_extent: float
) -> bool:
	return _guardian_circle_reaches_enemy(
		active_guardian_positions[active_slot],
		active_guardian_radii[active_slot],
		enemy,
		target_center,
		target_extent
	)


func _guardian_circle_reaches_enemy(
	aura_center: Vector2,
	aura_radius: float,
	enemy: Enemy,
	target_center: Vector2,
	target_extent: float
) -> bool:
	if collect_overlap_query_metrics:
		overlap_candidate_count += 1
	if use_extent_overlap_certificates and target_extent > 0.0:
		var center_distance_squared := aura_center.distance_squared_to(target_center)
		var outer_radius := aura_radius + target_extent
		if center_distance_squared > outer_radius * outer_radius:
			if collect_overlap_query_metrics:
				overlap_fast_reject_count += 1
			return false

		# If the aura contains the complete conservative target circle, at least
		# one enabled body shape is necessarily inside it. This is an exact
		# acceptance proof, not an approximation.
		if aura_radius >= target_extent:
			var containment_radius := aura_radius - target_extent
			if center_distance_squared <= containment_radius * containment_radius:
				if collect_overlap_query_metrics:
					overlap_fast_accept_count += 1
				return true

	if collect_overlap_query_metrics:
		overlap_exact_fallback_count += 1
	for shape_node in enemy.body_collision_shapes:
		if (
			shape_node != null
			and not shape_node.disabled
			and _circle_intersects_collision_shape(
				aura_center,
				aura_radius,
				shape_node
			)
		):
			return true
	return false


func _has_enabled_body_collision_shape(enemy: Enemy) -> bool:
	for shape_node in enemy.body_collision_shapes:
		if shape_node != null and not shape_node.disabled and shape_node.shape != null:
			return true
	return false


func _remove_tracked_enemy_id(enemy_id: int) -> void:
	if not tracked_enemy_slot_by_id.has(enemy_id):
		return
	var remove_slot := int(tracked_enemy_slot_by_id[enemy_id])
	var last_slot := tracked_enemy_ids.size() - 1
	tracked_enemy_slot_by_id.erase(enemy_id)
	if remove_slot < refresh_cursor:
		var processed_tail_slot := refresh_cursor - 1
		if remove_slot != processed_tail_slot:
			var processed_tail_id := tracked_enemy_ids[processed_tail_slot]
			tracked_enemy_ids[remove_slot] = processed_tail_id
			tracked_enemy_slot_by_id[processed_tail_id] = remove_slot
		if processed_tail_slot != last_slot:
			var last_enemy_id := tracked_enemy_ids[last_slot]
			tracked_enemy_ids[processed_tail_slot] = last_enemy_id
			tracked_enemy_slot_by_id[last_enemy_id] = processed_tail_slot
		refresh_cursor -= 1
	elif remove_slot != last_slot:
		var last_enemy_id := tracked_enemy_ids[last_slot]
		tracked_enemy_ids[remove_slot] = last_enemy_id
		tracked_enemy_slot_by_id[last_enemy_id] = remove_slot
	tracked_enemy_ids.pop_back()
	refresh_target_debt = minf(refresh_target_debt, float(tracked_enemy_ids.size()))


func _remove_guardian_id(source_id: int) -> void:
	if not guardian_slot_by_id.has(source_id):
		return
	var remove_slot := int(guardian_slot_by_id[source_id])
	var last_slot := guardian_ids.size() - 1
	guardian_slot_by_id.erase(source_id)
	if remove_slot < refresh_guardian_cursor:
		var processed_tail_slot := refresh_guardian_cursor - 1
		if remove_slot != processed_tail_slot:
			var processed_tail_id := guardian_ids[processed_tail_slot]
			guardian_ids[remove_slot] = processed_tail_id
			guardian_slot_by_id[processed_tail_id] = remove_slot
		if processed_tail_slot != last_slot:
			var last_guardian_id := guardian_ids[last_slot]
			guardian_ids[processed_tail_slot] = last_guardian_id
			guardian_slot_by_id[last_guardian_id] = processed_tail_slot
		refresh_guardian_cursor -= 1
	elif remove_slot != last_slot:
		var last_guardian_id := guardian_ids[last_slot]
		guardian_ids[remove_slot] = last_guardian_id
		guardian_slot_by_id[last_guardian_id] = remove_slot
	guardian_ids.pop_back()
	refresh_guardian_debt = minf(
		refresh_guardian_debt,
		float(guardian_ids.size())
	)
	# A partially visited source exclusively owns the retained candidates and
	# desired-membership scratch. Array compaction may move it away from the
	# ordinary processed-prefix cursor, so restore ownership from its stable ID
	# at the mutation boundary before another guardian can consume the slot.
	if pending_source_refresh_id != 0:
		refresh_guardian_cursor = int(
			guardian_slot_by_id[pending_source_refresh_id]
		)
	elif guardian_ids.is_empty() or refresh_guardian_cursor >= guardian_ids.size():
		refresh_guardian_cursor = 0


func _circle_intersects_collision_shape(
	circle_center: Vector2,
	circle_radius: float,
	shape_node: CollisionShape2D
) -> bool:
	if shape_node == null or shape_node.shape == null:
		return false
	var shape_transform := shape_node.global_transform
	var scale_x := shape_transform.x.length()
	var scale_y := shape_transform.y.length()
	var maximum_scale := maxf(scale_x, scale_y)
	var shape := shape_node.shape

	var circle_shape := shape as CircleShape2D
	if circle_shape != null:
		var combined_radius := circle_radius + circle_shape.radius * maximum_scale
		return circle_center.distance_squared_to(shape_transform.origin) <= combined_radius * combined_radius

	var capsule_shape := shape as CapsuleShape2D
	if capsule_shape != null:
		var half_segment := maxf(capsule_shape.height * 0.5 - capsule_shape.radius, 0.0)
		var segment_a := shape_transform * Vector2(0.0, -half_segment)
		var segment_b := shape_transform * Vector2(0.0, half_segment)
		var combined_radius := circle_radius + capsule_shape.radius * maximum_scale
		return _distance_squared_to_segment(circle_center, segment_a, segment_b) <= combined_radius * combined_radius

	var rectangle_shape := shape as RectangleShape2D
	if rectangle_shape != null:
		var local_center := shape_transform.affine_inverse() * circle_center
		var half_size := rectangle_shape.size * 0.5
		var closest_local := Vector2(
			clampf(local_center.x, -half_size.x, half_size.x),
			clampf(local_center.y, -half_size.y, half_size.y)
		)
		var closest_world := shape_transform * closest_local
		return circle_center.distance_squared_to(closest_world) <= circle_radius * circle_radius

	var segment_shape := shape as SegmentShape2D
	if segment_shape != null:
		var segment_a := shape_transform * segment_shape.a
		var segment_b := shape_transform * segment_shape.b
		return _distance_squared_to_segment(circle_center, segment_a, segment_b) <= circle_radius * circle_radius

	# Enemy 场景目前只使用以上四种 Shape2D。这个保守分支让新形状在接入专用
	# 几何判定前仍不会漏掉光环，但不会掩盖现有结构问题。
	var fallback_radius := _get_transformed_rect_extent_radius(shape_node)
	var combined_radius := circle_radius + fallback_radius
	return circle_center.distance_squared_to(shape_transform.origin) <= combined_radius * combined_radius


func _distance_squared_to_segment(point: Vector2, segment_a: Vector2, segment_b: Vector2) -> float:
	var segment := segment_b - segment_a
	var length_squared := segment.length_squared()
	if is_zero_approx(length_squared):
		return point.distance_squared_to(segment_a)
	var offset := clampf((point - segment_a).dot(segment) / length_squared, 0.0, 1.0)
	return point.distance_squared_to(segment_a + segment * offset)


func _get_transformed_rect_extent_radius(shape_node: CollisionShape2D) -> float:
	var shape_rect := shape_node.shape.get_rect()
	var maximum_radius := 0.0
	for corner in [
		shape_rect.position,
		shape_rect.position + Vector2(shape_rect.size.x, 0.0),
		shape_rect.position + Vector2(0.0, shape_rect.size.y),
		shape_rect.position + shape_rect.size,
	]:
		maximum_radius = maxf(
			maximum_radius,
			(shape_node.global_transform * (corner as Vector2)).distance_to(
				shape_node.global_position
			)
		)
	return maximum_radius


func _get_guardian_world_radius(
	guardian: Enemy,
	guardian_config: YuanshiInsectGuardianConfig
) -> float:
	var guardian_transform := guardian.global_transform
	var maximum_scale := maxf(guardian_transform.x.length(), guardian_transform.y.length())
	return maxf(guardian_config.aura_radius, 0.0) * maximum_scale


func _get_enemy_broadphase_extent(enemy: Enemy) -> float:
	var enemy_transform := enemy.global_transform
	var maximum_scale := maxf(enemy_transform.x.length(), enemy_transform.y.length())
	return enemy.body_collision_extent_radius * maximum_scale


func _world_to_cell(world_position: Vector2) -> Vector2i:
	var safe_cell_size := maxf(grid_cell_size, 1.0)
	return Vector2i(
		floori(world_position.x / safe_cell_size),
		floori(world_position.y / safe_cell_size)
	)


# 定向测试和诊断入口：生产更新仍只走受渲染帧限载的分批固定物理刷新。
func force_refresh_all() -> void:
	_prune_dead_or_invalid_enemies()
	_classify_pending_guardians()
	_refresh_maximum_tracked_target_extent()
	_clear_pending_source_refresh()
	if source_driven_refresh_enabled:
		_begin_source_query_index_scope()
		for source_id in guardian_ids.duplicate():
			var guardian := guardians.get(source_id) as Enemy
			if guardian != null and is_instance_valid(guardian) and not guardian.is_dead:
				if not _refresh_guardian_coverage(guardian):
					source_deferred_refresh_count += 1
		_end_source_query_index_scope()
	else:
		_rebuild_guardian_grid()
		for enemy_id in tracked_enemy_ids:
			var enemy := tracked_enemies.get(enemy_id) as Enemy
			if enemy != null and is_instance_valid(enemy) and not enemy.is_dead:
				_refresh_enemy_sources(enemy)
	refresh_cursor = 0
	refresh_target_debt = 0.0
	refresh_guardian_cursor = 0
	refresh_guardian_debt = 0.0


func _refresh_maximum_tracked_target_extent() -> void:
	maximum_tracked_target_extent = 0.0
	for enemy_id in tracked_enemy_ids:
		var enemy := tracked_enemies.get(enemy_id) as Enemy
		if enemy != null and is_instance_valid(enemy) and not enemy.is_dead:
			maximum_tracked_target_extent = maxf(
				maximum_tracked_target_extent,
				_get_enemy_broadphase_extent(enemy)
			)


func reset_overlap_query_metrics() -> void:
	overlap_candidate_count = 0
	overlap_fast_accept_count = 0
	overlap_fast_reject_count = 0
	overlap_exact_fallback_count = 0


func reset_runtime_performance_metrics() -> void:
	refresh_service_step_count = 0
	refresh_target_visit_count = 0
	refresh_budget_deferral_count = 0
	refresh_service_usec_total = 0
	maximum_refresh_service_usec = 0
	last_refresh_target_count = 0
	last_refresh_service_usec = 0
	source_refresh_count = 0
	source_candidate_visit_count = 0
	source_index_query_count = 0
	source_fallback_scan_count = 0
	source_deferred_refresh_count = 0
	source_unchanged_diff_skip_count = 0
	last_refresh_guardian_count = 0
	reset_overlap_query_metrics()


func get_runtime_performance_metrics() -> Dictionary:
	return {
		"tracked_enemies": tracked_enemy_ids.size(),
		"guardians": guardian_ids.size(),
		"service_steps": refresh_service_step_count,
		"target_visits": refresh_target_visit_count,
		"source_refreshes": source_refresh_count,
		"source_candidate_visits": source_candidate_visit_count,
		"source_index_queries": source_index_query_count,
		"source_fallback_scans": source_fallback_scan_count,
		"source_deferred_refreshes": source_deferred_refresh_count,
		"source_unchanged_diff_skips": source_unchanged_diff_skip_count,
		"budget_deferrals": refresh_budget_deferral_count,
		"service_usec": refresh_service_usec_total,
		"max_service_usec": maximum_refresh_service_usec,
		"remaining_target_debt": refresh_target_debt,
		"remaining_guardian_debt": refresh_guardian_debt,
		"candidates": overlap_candidate_count,
		"fast_accepts": overlap_fast_accept_count,
		"fast_rejects": overlap_fast_reject_count,
		"exact_fallbacks": overlap_exact_fallback_count,
	}


func has_guardian_source(enemy: Enemy, guardian: Enemy) -> bool:
	if enemy == null or guardian == null:
		return false
	var sources: Dictionary = aura_sources_by_enemy.get(enemy.get_instance_id(), {})
	return sources.has(guardian.get_instance_id())


func get_guardian_count() -> int:
	return guardian_ids.size()
