extends Node
class_name CombatRobotDroneMotionSystem

var drones: Array[CombatRobotSuicideDrone] = []
var drone_ids := PackedInt64Array()
var drone_slot_by_id: Dictionary[int, int] = {}
var pending_removal_ids: Dictionary[int, bool] = {}
var is_advancing := false


func _ready() -> void:
	set_physics_process(false)


func get_active_drone_count() -> int:
	return drones.size() - pending_removal_ids.size()


func has_drone(drone: CombatRobotSuicideDrone) -> bool:
	return (
		drone != null
		and drone_slot_by_id.has(drone.get_instance_id())
		and not pending_removal_ids.has(drone.get_instance_id())
	)


func register_drone(drone: CombatRobotSuicideDrone) -> void:
	if drone == null or not is_instance_valid(drone):
		return
	var previous_system := drone.batched_motion_system
	if (
		previous_system != null
		and previous_system != self
		and is_instance_valid(previous_system)
	):
		drone.batched_motion_system = null
		previous_system.call("unregister_drone", drone)
	var drone_id := drone.get_instance_id()
	if drone_slot_by_id.has(drone_id):
		pending_removal_ids.erase(drone_id)
		drone.batched_motion_system = self
		drone.batched_activation_physics_frame = Engine.get_physics_frames()
		set_physics_process(true)
		return
	drone_slot_by_id[drone_id] = drones.size()
	drones.append(drone)
	drone_ids.append(drone_id)
	drone.batched_motion_system = self
	drone.batched_activation_physics_frame = Engine.get_physics_frames()
	set_physics_process(true)


func unregister_drone(drone: CombatRobotSuicideDrone) -> void:
	if drone == null:
		return
	var drone_id := drone.get_instance_id()
	if drone.batched_motion_system == self:
		drone.batched_motion_system = null
	if not drone_slot_by_id.has(drone_id):
		return
	if is_advancing:
		pending_removal_ids[drone_id] = true
		return
	_remove_drone_id(drone_id)


func _physics_process(delta: float) -> void:
	if drones.is_empty():
		set_physics_process(false)
		return
	is_advancing = true
	var current_physics_frame := Engine.get_physics_frames()
	var initial_count := drones.size()
	for drone_index in range(initial_count):
		var drone := drones[drone_index]
		var drone_id := int(drone_ids[drone_index])
		if drone == null or not is_instance_valid(drone):
			pending_removal_ids[drone_id] = true
			continue
		if (
			pending_removal_ids.has(drone_id)
			or drone.batched_motion_system != self
			or not drone.pool_active
			or not drone.deployment_started
		):
			pending_removal_ids[drone_id] = true
			continue
		if current_physics_frame <= drone.batched_activation_physics_frame:
			continue
		drone.advance_batched(delta)
	is_advancing = false
	_flush_pending_removals()


func _flush_pending_removals() -> void:
	if pending_removal_ids.is_empty():
		return
	var removal_ids := pending_removal_ids.keys()
	pending_removal_ids.clear()
	for drone_id_variant in removal_ids:
		_remove_drone_id(int(drone_id_variant))


func _remove_drone_id(drone_id: int) -> void:
	if not drone_slot_by_id.has(drone_id):
		return
	var remove_slot := int(drone_slot_by_id[drone_id])
	var last_slot := drones.size() - 1
	var removed_drone := drones[remove_slot]
	if remove_slot != last_slot:
		var moved_drone := drones[last_slot]
		var moved_drone_id := int(drone_ids[last_slot])
		drones[remove_slot] = moved_drone
		drone_ids[remove_slot] = moved_drone_id
		drone_slot_by_id[moved_drone_id] = remove_slot
	drones.pop_back()
	drone_ids.resize(last_slot)
	drone_slot_by_id.erase(drone_id)
	if (
		removed_drone != null
		and is_instance_valid(removed_drone)
		and removed_drone.batched_motion_system == self
	):
		removed_drone.batched_motion_system = null
	if drones.is_empty():
		set_physics_process(false)


func _exit_tree() -> void:
	for drone in drones:
		if (
			drone != null
			and is_instance_valid(drone)
			and drone.batched_motion_system == self
		):
			drone.batched_motion_system = null
	drones.clear()
	drone_ids.clear()
	drone_slot_by_id.clear()
	pending_removal_ids.clear()
