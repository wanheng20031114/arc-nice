extends PickupRegistryBase
class_name StandardPickupRegistry


func bind_standard_dependencies(
	mode: int,
	runtime: CombatRuntimeBase,
	gameplay_gateway: MultiplayerGameplayGateway,
	enemy_container: Node2D,
	boss_container: Node2D
) -> void:
	var dynamic_containers: Array[Node] = [enemy_container, boss_container]
	bind_dependencies(
		mode,
		runtime,
		gameplay_gateway,
		dynamic_containers
	)
