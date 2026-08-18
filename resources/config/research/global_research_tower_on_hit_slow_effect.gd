extends GlobalResearchEffect
class_name GlobalResearchTowerOnHitSlowEffect

@export var source_tower_id: StringName = &""
@export_range(0.001, 0.999, 0.001) var slow_ratio: float = 0.25
@export_range(0.01, 3600.0, 0.01, "or_greater") var duration_seconds := 3.0


func is_valid() -> bool:
	return (
		source_tower_id != &""
		and is_finite(slow_ratio)
		and slow_ratio > 0.0
		and slow_ratio < 1.0
		and is_finite(duration_seconds)
		and duration_seconds > 0.0
	)


func get_semantic_key() -> StringName:
	return StringName("tower_on_hit_slow:%s" % String(source_tower_id))


func get_move_speed_multiplier() -> float:
	return 1.0 - slow_ratio
