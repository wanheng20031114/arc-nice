extends Node
class_name PickupRegistryBase

const FIRST_DYNAMIC_PICKUP_NET_ID := 1000

var runtime_mode := CombatRuntimeBase.RuntimeMode.SINGLEPLAYER
var next_multiplayer_pickup_net_id := FIRST_DYNAMIC_PICKUP_NET_ID
var pending_multiplayer_pickup_exit_ids: Dictionary = {}

var _pickup_index: Dictionary = {}
var _gameplay_gateway: MultiplayerGameplayGateway
var _dynamic_containers: Array[Node] = []
var _bound := false


func bind_dependencies(
	mode: int,
	pickup_index: Dictionary,
	gameplay_gateway: MultiplayerGameplayGateway,
	dynamic_containers: Array[Node],
	pending_exit_ids: Dictionary,
	next_pickup_net_id: int
) -> void:
	runtime_mode = mode
	_pickup_index = pickup_index
	_gameplay_gateway = gameplay_gateway
	_dynamic_containers = dynamic_containers.duplicate()
	pending_multiplayer_pickup_exit_ids = pending_exit_ids
	next_multiplayer_pickup_net_id = next_pickup_net_id
	_bound = _gameplay_gateway != null and not _dynamic_containers.is_empty()
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
	_pickup_index.clear()
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
	return get_pickup_from_index(_pickup_index, net_id)


func mark_multiplayer_pickup_removed(
	net_id: int,
	suppress_next_tree_exit: bool = false
) -> bool:
	if net_id <= 0 or _gameplay_gateway == null:
		return false
	if suppress_next_tree_exit:
		if pending_multiplayer_pickup_exit_ids.has(net_id):
			return false
		pending_multiplayer_pickup_exit_ids[net_id] = true
	elif pending_multiplayer_pickup_exit_ids.erase(net_id):
		return false
	_pickup_index.erase(net_id)
	_gameplay_gateway.pickup_removed.emit(net_id)
	return true


func handle_multiplayer_pickup_consumed(
	pickup: Pickup,
	collector_peer_id: int,
	applied_immediately: bool
) -> void:
	if pickup == null:
		return
	var net_id := int(pickup.get_meta("net_id", 0))
	if net_id <= 0:
		return
	if not mark_multiplayer_pickup_removed(net_id, true):
		return
	_gameplay_gateway.pickup_collected.emit(
		net_id,
		collector_peer_id,
		pickup.config,
		applied_immediately
	)


func handle_multiplayer_pickup_tree_exited(net_id: int) -> void:
	if runtime_mode != CombatRuntimeBase.RuntimeMode.HOST_AUTHORITY:
		return
	mark_multiplayer_pickup_removed(net_id)


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
	if int(pickup.get_meta("net_id", 0)) > 0:
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
	pickup.set_meta("net_id", net_id)
	_pickup_index[net_id] = pickup
	if runtime_mode != CombatRuntimeBase.RuntimeMode.HOST_AUTHORITY:
		return
	if not pickup.consumed.is_connected(handle_multiplayer_pickup_consumed):
		pickup.consumed.connect(handle_multiplayer_pickup_consumed)
	var tree_exit_callback := handle_multiplayer_pickup_tree_exited.bind(net_id)
	if not pickup.tree_exited.is_connected(tree_exit_callback):
		pickup.tree_exited.connect(tree_exit_callback)
	if broadcast_spawn:
		_gameplay_gateway.pickup_spawned.emit(
			net_id,
			pickup.config,
			pickup.global_position
		)


static func get_pickup_from_index(pickup_index: Dictionary, net_id: int) -> Pickup:
	if not pickup_index.has(net_id):
		return null
	var pickup_variant: Variant = pickup_index.get(net_id)
	if pickup_variant == null or not is_instance_valid(pickup_variant):
		pickup_index.erase(net_id)
		return null
	return pickup_variant as Pickup
