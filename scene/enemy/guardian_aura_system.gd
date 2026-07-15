extends Node
class_name GuardianAuraSystem

## 守卫光环不再依赖每只守卫的 Area2D 持续生成物理重叠对。
## 本节点在敌人完成物理移动后，以粗网格和固定刷新周期分批维护来源精确的防御修正。

const ENEMY_COLLISION_LAYER := 4

@export var enemy_container_path := NodePath("../EnemyContainer")
@export var target_container_paths: Array[NodePath] = [
	NodePath("../EnemyContainer"),
	NodePath("../BossContainer"),
]
@export_range(16.0, 256.0, 1.0, "or_greater") var grid_cell_size := 64.0
@export_range(0.02, 0.5, 0.01, "or_greater") var refresh_interval_seconds := 0.1

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
var guardian_grid: Dictionary[Vector2i, Array] = {}
var desired_sources_scratch: Dictionary[int, int] = {}
var current_source_ids_scratch: Array[int] = []
var maximum_guardian_radius := 0.0
var refresh_cursor := 0


func _ready() -> void:
	enemy_container = get_node_or_null(enemy_container_path)
	if enemy_container == null:
		push_error(
			"GuardianAuraSystem could not resolve EnemyContainer at %s."
			% enemy_container_path
		)
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
	desired_sources_scratch.clear()
	current_source_ids_scratch.clear()


func _physics_process(delta: float) -> void:
	_classify_pending_guardians()
	_rebuild_guardian_grid()
	_process_refresh_batch(delta)


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
	_track_enemy(child as Enemy, target_container == enemy_container)


func _on_target_container_child_exiting(child: Node, _target_container: Node) -> void:
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
	if enemy == null:
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


func _remove_guardian_source(source_id: int) -> void:
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
	guardians.erase(source_id)
	_remove_guardian_id(source_id)


func _clear_all_guardian_sources() -> void:
	for source_id_variant in guardian_ids.duplicate():
		_remove_guardian_source(int(source_id_variant))


func _rebuild_guardian_grid() -> void:
	guardian_grid.clear()
	maximum_guardian_radius = 0.0
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


func _process_refresh_batch(delta: float) -> void:
	var enemy_count := tracked_enemy_ids.size()
	if enemy_count <= 0:
		refresh_cursor = 0
		return
	if delta <= 0.0:
		# 零逻辑时间内位置不会发生变化；死亡/移除仍由同步信号路径清理。
		return

	# 用完整物理 tick 计算批量。低 tick 率时自动增大批次，确保一次完整轮询
	# 不晚于 refresh_interval_seconds（或单个物理 tick，以较大者为准）。
	var ticks_per_refresh := maxi(
		floori(refresh_interval_seconds / delta + 0.0001),
		1
	)
	var batch_size := clampi(
		ceili(float(enemy_count) / float(ticks_per_refresh)),
		1,
		enemy_count
	)
	for _batch_index in range(batch_size):
		if tracked_enemy_ids.is_empty():
			refresh_cursor = 0
			return
		if refresh_cursor >= tracked_enemy_ids.size():
			refresh_cursor = 0
		var enemy_id := tracked_enemy_ids[refresh_cursor]
		refresh_cursor += 1
		var enemy := tracked_enemies.get(enemy_id) as Enemy
		if enemy == null or not is_instance_valid(enemy) or enemy.is_dead:
			# Normal defeat and container removal are synchronous. This bounded audit
			# is the safety net for an abnormal missed signal, folded into the same
			# cursor that already visits every target once per refresh interval.
			_untrack_enemy_id(enemy_id)
			continue
		_refresh_enemy_sources(enemy)


func _refresh_enemy_sources(enemy: Enemy) -> void:
	var enemy_id := enemy.get_instance_id()
	# Refreshes are synchronous and processed one enemy at a time, so one reused
	# dictionary removes a short-lived allocation from every aura target refresh.
	desired_sources_scratch.clear()
	if (
		(enemy.collision_layer & ENEMY_COLLISION_LAYER) != 0
		and not guardian_grid.is_empty()
	):
		var search_radius := maximum_guardian_radius + _get_enemy_broadphase_extent(enemy)
		var cell_radius := ceili(search_radius / maxf(grid_cell_size, 1.0))
		var center_cell := _world_to_cell(enemy.global_position)
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
					if _guardian_reaches_enemy(guardian, guardian_config, enemy):
						desired_sources_scratch[source_id] = (
							guardian_config.aura_physical_defense_bonus
						)

	_apply_source_diff(enemy, desired_sources_scratch)


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
	enemy: Enemy
) -> bool:
	var aura_center := guardian.global_position
	var aura_radius := _get_guardian_world_radius(guardian, guardian_config)
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


func _remove_guardian_id(source_id: int) -> void:
	if not guardian_slot_by_id.has(source_id):
		return
	var remove_slot := int(guardian_slot_by_id[source_id])
	var last_slot := guardian_ids.size() - 1
	guardian_slot_by_id.erase(source_id)
	if remove_slot != last_slot:
		var last_guardian_id := guardian_ids[last_slot]
		guardian_ids[remove_slot] = last_guardian_id
		guardian_slot_by_id[last_guardian_id] = remove_slot
	guardian_ids.pop_back()


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


# 定向测试和诊断入口：生产更新仍只走分批固定物理刷新。
func force_refresh_all() -> void:
	_prune_dead_or_invalid_enemies()
	_classify_pending_guardians()
	_rebuild_guardian_grid()
	for enemy_id in tracked_enemy_ids:
		var enemy := tracked_enemies.get(enemy_id) as Enemy
		if enemy != null and is_instance_valid(enemy) and not enemy.is_dead:
			_refresh_enemy_sources(enemy)
	refresh_cursor = 0


func has_guardian_source(enemy: Enemy, guardian: Enemy) -> bool:
	if enemy == null or guardian == null:
		return false
	var sources: Dictionary = aura_sources_by_enemy.get(enemy.get_instance_id(), {})
	return sources.has(guardian.get_instance_id())


func get_guardian_count() -> int:
	return guardian_ids.size()
