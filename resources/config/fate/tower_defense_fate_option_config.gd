extends Resource
class_name TowerDefenseFateOptionConfig

enum EffectType {
	PERMANENT_ELITE_CONTRACT,
	BASE_REBUILD,
	COLLECTIBLE_REWARD,
	FATE_STONE,
	XIRANG_GIFT,
	DASH_COOLDOWN,
	MAX_HEALTH,
	CRITICAL_RANDOM_BUFF,
	DOUBLE_XIRANG,
	DANGEROUS_SPEED,
}

@export var option_id: StringName = &""
@export_range(10, 1000, 10) var menu_order := 10
@export var display_name := "命运选项"
@export_multiline var description := ""
@export var effect_type := EffectType.PERMANENT_ELITE_CONTRACT
@export var primary_amount := 0.0
@export var secondary_amount := 0.0
@export var duration_seconds := 0.0
@export var icon: Texture2D = null


func is_valid() -> bool:
	return (
		option_id != &""
		and menu_order > 0
		and not display_name.is_empty()
		and not description.is_empty()
		and effect_type >= EffectType.PERMANENT_ELITE_CONTRACT
		and effect_type <= EffectType.DANGEROUS_SPEED
		and is_finite(primary_amount)
		and is_finite(secondary_amount)
		and is_finite(duration_seconds)
		and duration_seconds >= 0.0
	)


func requires_available_permanent_buff() -> bool:
	return effect_type in [
		EffectType.PERMANENT_ELITE_CONTRACT,
		EffectType.CRITICAL_RANDOM_BUFF,
	]
