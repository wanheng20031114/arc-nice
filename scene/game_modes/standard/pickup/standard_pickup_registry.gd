extends PickupRegistryBase
class_name StandardPickupRegistry


func bind_standard_dependencies(
	mode: int,
	pickup_index: Dictionary,
	gameplay_gateway: MultiplayerGameplayGateway,
	enemy_container: Node2D,
	boss_container: Node2D,
	pending_exit_ids: Dictionary,
	next_pickup_net_id: int
) -> void:
	var dynamic_containers: Array[Node] = [enemy_container, boss_container]
	bind_dependencies(
		mode,
		pickup_index,
		gameplay_gateway,
		dynamic_containers,
		pending_exit_ids,
		next_pickup_net_id
	)
