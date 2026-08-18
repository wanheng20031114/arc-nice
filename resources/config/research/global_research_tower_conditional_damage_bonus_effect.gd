extends GlobalResearchEffect
class_name GlobalResearchTowerConditionalDamageBonusEffect

const STATUS_ELECTROMAGNETIC: StringName = &"electromagnetic"
const SUPPORTED_STATUSES: Array[StringName] = [STATUS_ELECTROMAGNETIC]

@export var source_tower_id: StringName = &""
@export var required_status_id: StringName = &""
@export_range(0.001, 100.0, 0.001, "or_greater") var bonus_damage_ratio := 0.5


func is_valid() -> bool:
	return (
		source_tower_id != &""
		and required_status_id in SUPPORTED_STATUSES
		and is_finite(bonus_damage_ratio)
		and bonus_damage_ratio > 0.0
	)


func get_semantic_key() -> StringName:
	return StringName(
		"tower_conditional_damage:%s:%s"
		% [String(source_tower_id), String(required_status_id)]
	)
