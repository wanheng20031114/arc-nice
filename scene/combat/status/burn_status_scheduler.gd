extends PeriodicDamageStatusScheduler

const BURN_TICK_INTERVAL_SECONDS := 1.0


func apply_burn(
	target: Object,
	tick_callback: Callable,
	source_family: StringName,
	duration: float,
	tick_damage: int,
	state_callback: Callable = Callable(),
	source_snapshot: DamageSourceSnapshot = null
) -> bool:
	return apply_periodic_status(
		target,
		tick_callback,
		source_family,
		duration,
		tick_damage,
		BURN_TICK_INTERVAL_SECONDS,
		TickPolicy.STRONGEST_SOURCE,
		state_callback,
		source_snapshot
	)


func has_burn(target: Object, source_family: StringName = &"") -> bool:
	return has_status(target, source_family)


## Compatibility seam for deterministic smoke tests and profiling tools.
func _advance_active_burns(delta: float) -> void:
	_advance_active_statuses(delta)
