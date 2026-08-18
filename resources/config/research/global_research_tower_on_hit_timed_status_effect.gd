extends GlobalResearchEffect
class_name GlobalResearchTowerOnHitTimedStatusEffect

const STATUS_ELECTROMAGNETIC: StringName = &"electromagnetic"
const SUPPORTED_STATUSES: Array[StringName] = [STATUS_ELECTROMAGNETIC]

@export var source_tower_id: StringName = &""
@export var status_id: StringName = &""
@export_range(0.01, 3600.0, 0.01, "or_greater") var duration_seconds := 10.0


func is_valid() -> bool:
	return (
		source_tower_id != &""
		and status_id in SUPPORTED_STATUSES
		and is_finite(duration_seconds)
		and duration_seconds > 0.0
	)


func get_semantic_key() -> StringName:
	return StringName(
		"tower_on_hit_status:%s:%s"
		% [String(source_tower_id), String(status_id)]
	)
