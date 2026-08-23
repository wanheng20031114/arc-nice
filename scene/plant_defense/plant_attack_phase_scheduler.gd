extends RefCounted
class_name PlantAttackPhaseScheduler

const MIN_SAFE_INTERVAL_SECONDS := 0.001
const GOLDEN_RATIO_CONJUGATE := 0.61803398875


## Returns a deterministic point inside one attack interval. A positive network
## identity keeps peers and restored saves on the same phase; callers may use a
## stable placement identity when no network identity exists.
static func calculate_initial_delay_seconds(
	attack_interval_seconds: float,
	phase_identity: int,
	minimum_delay_seconds: float
) -> float:
	var safe_interval := maxf(
		attack_interval_seconds,
		MIN_SAFE_INTERVAL_SECONDS
	)
	var safe_minimum_delay := clampf(
		minimum_delay_seconds,
		0.0,
		safe_interval
	)
	if safe_interval <= safe_minimum_delay:
		return safe_interval
	var phase_window := safe_interval - safe_minimum_delay
	return (
		safe_minimum_delay
		+ fposmod(
			float(phase_identity)
			* GOLDEN_RATIO_CONJUGATE
			* safe_interval,
			phase_window
		)
	)


static func resolve_plant_identity(plant: Node2D) -> int:
	var network_identity := int(plant.get_meta(&"net_id", 0))
	if network_identity > 0:
		return network_identity
	# Single-player placement assigns its local net id after setup. The rounded
	# world position is already final here and remains stable across save/load.
	return int(hash(Vector2i(
		roundi(plant.global_position.x),
		roundi(plant.global_position.y)
	)))
