extends GlobalResearchEffect
class_name GlobalResearchMultiplierModifierEffect

const METRIC_VEGETATION_STAKE_SPREAD_SPEED: StringName = (
	&"plant.vegetation_stake.spread_speed"
)
const METRIC_WATER_COLLECTOR_CYCLE_DURATION: StringName = (
	&"plant.water_collector.cycle_duration"
)
const SUPPORTED_METRICS: Array[StringName] = [
	METRIC_VEGETATION_STAKE_SPREAD_SPEED,
	METRIC_WATER_COLLECTOR_CYCLE_DURATION,
]

@export var metric_id: StringName = &""
@export var multiplier: float = 1.0


func is_valid() -> bool:
	if (
		metric_id not in SUPPORTED_METRICS
		or not is_finite(multiplier)
		or multiplier <= 0.0
	):
		return false
	return (
		metric_id != METRIC_WATER_COLLECTOR_CYCLE_DURATION
		or multiplier <= 1.0
	)


func get_semantic_key() -> StringName:
	return StringName("multiplier:%s" % String(metric_id))
