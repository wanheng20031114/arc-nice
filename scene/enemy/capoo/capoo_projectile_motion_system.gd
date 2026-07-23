extends Node
class_name CapooProjectileMotionSystem

var projectiles: Array[CapooAK47Bullet] = []
var projectile_ids := PackedInt64Array()
var projectile_slot_by_id: Dictionary[int, int] = {}
var pending_removal_ids: Dictionary[int, bool] = {}
var is_advancing := false


func get_active_projectile_count() -> int:
	return projectiles.size()


func has_projectile(projectile: CapooAK47Bullet) -> bool:
	return (
		projectile != null
		and projectile_slot_by_id.has(projectile.get_instance_id())
		and not pending_removal_ids.has(projectile.get_instance_id())
	)


func register_projectile(projectile: CapooAK47Bullet) -> void:
	if projectile == null or not is_instance_valid(projectile):
		return
	var previous_system = projectile.batched_motion_system
	if (
		previous_system != null
		and previous_system != self
		and is_instance_valid(previous_system)
	):
		projectile.batched_motion_system = null
		previous_system.call("unregister_projectile", projectile)
	var projectile_id := projectile.get_instance_id()
	if projectile_slot_by_id.has(projectile_id):
		pending_removal_ids.erase(projectile_id)
		projectile.batched_motion_system = self
		projectile.batched_activation_physics_frame = Engine.get_physics_frames()
		projectile.set_physics_process(false)
		return
	projectile_slot_by_id[projectile_id] = projectiles.size()
	projectiles.append(projectile)
	projectile_ids.append(projectile_id)
	projectile.batched_motion_system = self
	projectile.batched_activation_physics_frame = Engine.get_physics_frames()
	projectile.set_physics_process(false)


func unregister_projectile(projectile: CapooAK47Bullet) -> void:
	if projectile == null:
		return
	var projectile_id := projectile.get_instance_id()
	if projectile.batched_motion_system == self:
		projectile.batched_motion_system = null
	if not projectile_slot_by_id.has(projectile_id):
		return
	if is_advancing:
		pending_removal_ids[projectile_id] = true
		return
	_remove_projectile_id(projectile_id)


func _physics_process(delta: float) -> void:
	if projectiles.is_empty():
		return
	is_advancing = true
	var current_physics_frame := Engine.get_physics_frames()
	var initial_count := projectiles.size()
	for projectile_index in range(initial_count):
		var projectile := projectiles[projectile_index]
		var projectile_id := int(projectile_ids[projectile_index])
		if projectile == null or not is_instance_valid(projectile):
			pending_removal_ids[projectile_id] = true
			continue
		if (
			pending_removal_ids.has(projectile_id)
			or projectile.batched_motion_system != self
			or projectile.has_hit
			or not projectile.pool_active
		):
			pending_removal_ids[projectile_id] = true
			continue
		# Newly fired projectiles begin moving on the next physics tick, matching
		# the former per-node callback activation boundary.
		if current_physics_frame <= projectile.batched_activation_physics_frame:
			continue
		projectile.advance_batched(delta)
	is_advancing = false
	_flush_pending_removals()


func _flush_pending_removals() -> void:
	if pending_removal_ids.is_empty():
		return
	var removal_ids := pending_removal_ids.keys()
	pending_removal_ids.clear()
	for projectile_id_variant in removal_ids:
		_remove_projectile_id(int(projectile_id_variant))


func _remove_projectile_id(projectile_id: int) -> void:
	if not projectile_slot_by_id.has(projectile_id):
		return
	var remove_slot := int(projectile_slot_by_id[projectile_id])
	var last_slot := projectiles.size() - 1
	var removed_projectile := projectiles[remove_slot]
	if remove_slot != last_slot:
		var moved_projectile := projectiles[last_slot]
		var moved_projectile_id := int(projectile_ids[last_slot])
		projectiles[remove_slot] = moved_projectile
		projectile_ids[remove_slot] = moved_projectile_id
		projectile_slot_by_id[moved_projectile_id] = remove_slot
	projectiles.pop_back()
	projectile_ids.resize(last_slot)
	projectile_slot_by_id.erase(projectile_id)
	if (
		removed_projectile != null
		and is_instance_valid(removed_projectile)
		and removed_projectile.batched_motion_system == self
	):
		removed_projectile.batched_motion_system = null


func _exit_tree() -> void:
	for projectile in projectiles:
		if (
			projectile != null
			and is_instance_valid(projectile)
			and projectile.batched_motion_system == self
		):
			projectile.batched_motion_system = null
			if projectile.pool_active and not projectile.has_hit:
				projectile.set_physics_process(true)
	projectiles.clear()
	projectile_ids.clear()
	projectile_slot_by_id.clear()
	pending_removal_ids.clear()
