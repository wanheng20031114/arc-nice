extends PickupRegistryBase
class_name RoguePickupRegistry


func bind_rogue_dependencies(
	mode: int,
	runtime: CombatRuntimeBase,
	gameplay_gateway: MultiplayerGameplayGateway,
	enemy_container: Node2D
) -> void:
	var dynamic_containers: Array[Node] = [enemy_container]
	bind_dependencies(
		mode,
		runtime,
		gameplay_gateway,
		dynamic_containers
	)
