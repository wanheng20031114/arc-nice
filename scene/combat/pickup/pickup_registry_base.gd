extends Node
class_name PickupRegistryBase

const FIRST_DYNAMIC_PICKUP_NET_ID := 1000

var runtime_mode := CombatRuntimeBase.RuntimeMode.SINGLEPLAYER
var next_multiplayer_pickup_net_id := FIRST_DYNAMIC_PICKUP_NET_ID
var pending_multiplayer_pickup_exit_ids: Dictionary = {}

var _runtime: CombatRuntimeBase
var _gameplay_gateway: MultiplayerGameplayGateway
var _dynamic_containers: Array[Node] = []
var _bound := false


func bind_dependencies(
	mode: int,
	runtime: CombatRuntimeBase,
	gameplay_gateway: MultiplayerGameplayGateway,
	dynamic_containers: Array[Node]
) -> void:
	runtime_mode = mode
	_runtime = runtime
	_gameplay_gateway = gameplay_gateway
	_dynamic_containers = dynamic_containers.duplicate()
	_bound = (
		_runtime != null
		and _gameplay_gateway != null
		and not _dynamic_containers.is_empty()
	)
	for container in _dynamic_containers:
		if container == null:
			_bound = false
			break


func is_bound() -> bool:
	return _bound


func set_runtime_mode(mode: int) -> void:
	runtime_mode = mode


func connect_dynamic_containers() -> void:
	for container in _dynamic_containers:
		if not container.child_entered_tree.is_connected(
			_on_dynamic_pickup_container_child_entered
		):
			container.child_entered_tree.connect(
				_on_dynamic_pickup_container_child_entered
			)


func register_static_pickups(static_root: Node) -> void:
	if _runtime == null:
		return
	_runtime.clear_network_pickup_registry()
	pending_multiplayer_pickup_exit_ids.clear()
	next_multiplayer_pickup_net_id = FIRST_DYNAMIC_PICKUP_NET_ID
	if static_root == null:
		return
	var pickups: Array[Pickup] = []
	_collect_pickups_recursive(static_root, pickups)
	pickups.sort_custom(_sort_pickups_by_path)
	var next_pickup_id := 1
	for pickup in pickups:
		if pickup == null or not is_instance_valid(pickup):
			continue
		_register_multiplayer_pickup(pickup, next_pickup_id, false)
		next_pickup_id += 1


func register_existing_dynamic_pickups() -> void:
	for container in _dynamic_containers:
		for child in container.get_children():
			_register_dynamic_multiplayer_pickup(child as Pickup)


func get_pickup_for_net_id(net_id: int) -> Pickup:
	return _runtime.get_network_pickup(net_id) if _runtime != null else null


func get_registered_pickup_ids() -> Array[int]:
	return _runtime.get_network_pickup_ids() if _runtime != null else []


func register_remote_pickup(net_id: int, pickup: Pickup) -> bool:
	if (
		runtime_mode != CombatRuntimeBase.RuntimeMode.CLIENT_VIEW
		or _runtime == null
	):
		return false
	return _runtime.register_network_pickup(net_id, pickup)


func remove_remote_pickup(net_id: int, expected_pickup: Pickup = null) -> Pickup:
	if (
		runtime_mode != CombatRuntimeBase.RuntimeMode.CLIENT_VIEW
		or _runtime == null
	):
		return null
	return _runtime.unregister_network_pickup(net_id, expected_pickup)


func mark_multiplayer_pickup_removed(
	net_id: int,
	suppress_next_tree_exit: bool = false,
	expected_pickup: Pickup = null
) -> bool:
	if net_id <= 0 or _runtime == null or _gameplay_gateway == null:
		return false
	if suppress_next_tree_exit:
		if pending_multiplayer_pickup_exit_ids.has(net_id):
			return false
	elif pending_multiplayer_pickup_exit_ids.erase(net_id):
		return false
	if _runtime.unregister_network_pickup(net_id, expected_pickup) == null:
		return false
	if suppress_next_tree_exit:
		pending_multiplayer_pickup_exit_ids[net_id] = true
	_gameplay_gateway.pickup_removed.emit(net_id)
	return true


func _claim_multiplayer_pickup_consumption(
	net_id: int,
	expected_pickup: Pickup
) -> bool:
	if (
		net_id <= 0
		or expected_pickup == null
		or _runtime == null
		or _gameplay_gateway == null
		or pending_multiplayer_pickup_exit_ids.has(net_id)
	):
		return false
	if _runtime.unregister_network_pickup(net_id, expected_pickup) == null:
		return false
	# Collection is one atomic world terminal. Suppress the consumed node's later
	# tree-exit callback without publishing a competing generic removal packet.
	pending_multiplayer_pickup_exit_ids[net_id] = true
	return true


func handle_multiplayer_pickup_consumed(
	pickup: Pickup,
	collector_peer_id: int,
	applied_immediately: bool
) -> void:
	if pickup == null or _runtime == null:
		return
	var net_id := _runtime.get_network_pickup_net_id_by_instance_id(
		pickup.get_instance_id()
	)
	if net_id <= 0:
		return
	if not _claim_multiplayer_pickup_consumption(net_id, pickup):
		return
	_gameplay_gateway.pickup_collected.emit(
		net_id,
		collector_peer_id,
		pickup.config,
		applied_immediately
	)


func handle_multiplayer_pickup_tree_exited(
	net_id: int,
	exiting_pickup: Pickup = null
) -> void:
	if runtime_mode != CombatRuntimeBase.RuntimeMode.HOST_AUTHORITY:
		return
	mark_multiplayer_pickup_removed(net_id, false, exiting_pickup)


func _on_dynamic_pickup_container_child_entered(child: Node) -> void:
	if runtime_mode != CombatRuntimeBase.RuntimeMode.HOST_AUTHORITY:
		return
	var pickup := child as Pickup
	if pickup == null:
		return
	# Drop scripts assign global_position immediately after add_child(). Defer one
	# turn so the spawn event observes that final position rather than the parent.
	call_deferred(
		"_register_dynamic_multiplayer_pickup_from_ref",
		weakref(pickup)
	)


func _register_dynamic_multiplayer_pickup_from_ref(pickup_ref: WeakRef) -> void:
	if pickup_ref == null:
		return
	_register_dynamic_multiplayer_pickup(pickup_ref.get_ref() as Pickup)


func _register_dynamic_multiplayer_pickup(pickup: Pickup) -> void:
	if runtime_mode != CombatRuntimeBase.RuntimeMode.HOST_AUTHORITY:
		return
	if pickup == null or not is_instance_valid(pickup) or pickup.is_queued_for_deletion():
		return
	if (
		_runtime != null
		and _runtime.get_network_pickup_net_id_by_instance_id(
			pickup.get_instance_id()
		) > 0
	):
		return
	var net_id := next_multiplayer_pickup_net_id
	next_multiplayer_pickup_net_id += 1
	_register_multiplayer_pickup(pickup, net_id, true)


func _collect_pickups_recursive(node: Node, pickups: Array[Pickup]) -> void:
	for child in node.get_children():
		var pickup := child as Pickup
		if pickup != null:
			pickups.append(pickup)
		_collect_pickups_recursive(child, pickups)


func _sort_pickups_by_path(a: Pickup, b: Pickup) -> bool:
	return str(a.get_path()) < str(b.get_path())


func _register_multiplayer_pickup(
	pickup: Pickup,
	net_id: int,
	broadcast_spawn: bool
) -> void:
	if _runtime == null or not _runtime.register_network_pickup(net_id, pickup):
		return
	if runtime_mode != CombatRuntimeBase.RuntimeMode.HOST_AUTHORITY:
		return
	if not pickup.consumed.is_connected(handle_multiplayer_pickup_consumed):
		pickup.consumed.connect(handle_multiplayer_pickup_consumed)
	var tree_exit_callback := handle_multiplayer_pickup_tree_exited.bind(net_id, pickup)
	if not pickup.tree_exited.is_connected(tree_exit_callback):
		pickup.tree_exited.connect(tree_exit_callback)
	if broadcast_spawn:
		_gameplay_gateway.pickup_spawned.emit(
			net_id,
			pickup.config,
			pickup.global_position
		)
