extends PeriodicDamageStatusScheduler

const DEFAULT_BLEED_TICK_INTERVAL_SECONDS := 0.5
const MIN_BLEED_TICK_INTERVAL_SECONDS := 0.1


func apply_bleed(
	target: Object,
	tick_callback: Callable,
	source_family: StringName,
	duration: float,
	tick_damage: int,
	tick_interval: float = DEFAULT_BLEED_TICK_INTERVAL_SECONDS,
	state_callback: Callable = Callable()
) -> bool:
	return apply_periodic_status(
		target,
		tick_callback,
		source_family,
		duration,
		tick_damage,
		maxf(tick_interval, MIN_BLEED_TICK_INTERVAL_SECONDS),
		TickPolicy.ALL_SOURCES,
		state_callback
	)


func has_bleed(target: Object, source_family: StringName = &"") -> bool:
	return has_status(target, source_family)
