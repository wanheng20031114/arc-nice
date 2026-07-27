extends Resource
class_name TowerDefensePermanentBuffConfig

enum EffectType {
	BUILDING_REGENERATION,
	YUANSHI_ATTACK_REDUCTION,
	ARTIFICIAL_DEFENSE_REDUCTION,
	PLAYER_REGENERATION,
	SLIME_SPEED_REDUCTION,
	ENEMY_MAX_HEALTH_REDUCTION,
	ENEMY_SPEED_REDUCTION,
	LUOXI_EXTRA_CHOICE,
	LOW_HEALTH_DAMAGE_REDUCTION,
}

@export var buff_id: StringName = &""
@export_range(10, 1000, 10) var menu_order := 10
@export var display_name := "永久增益"
@export_multiline var description := ""
@export var effect_type := EffectType.BUILDING_REGENERATION
@export var magnitude := 0.0
@export var secondary_magnitude := 0.0


func is_valid() -> bool:
	return (
		buff_id != &""
		and menu_order > 0
		and not display_name.is_empty()
		and not description.is_empty()
		and effect_type >= EffectType.BUILDING_REGENERATION
		and effect_type <= EffectType.LOW_HEALTH_DAMAGE_REDUCTION
		and is_finite(magnitude)
		and magnitude > 0.0
		and is_finite(secondary_magnitude)
		and secondary_magnitude >= 0.0
	)
