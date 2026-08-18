extends GlobalResearchEffect
class_name GlobalResearchAdditiveModifierEffect

const ATTRIBUTE_BUILDING_PHYSICAL_DEFENSE: StringName = (
	&"building.all.physical_defense"
)
const ATTRIBUTE_PLAYER_MOVE_SPEED: StringName = &"player.all.move_speed"
const ATTRIBUTE_GRASS_HEAL_MAX_HEALTH_RATIO: StringName = (
	&"terrain.grass.heal_max_health_ratio_per_second"
)
const ATTRIBUTE_FENCE_MAX_HEALTH: StringName = &"building.fence.max_health"
const ATTRIBUTE_FENCE_PHYSICAL_DEFENSE: StringName = (
	&"building.fence.physical_defense"
)
const ATTRIBUTE_AGAVE_CANNON_ATTACK_DAMAGE: StringName = (
	&"plant.agave_cannon.attack_damage"
)
const ATTRIBUTE_CORN_MACHINE_GUN_BURST_COUNT: StringName = (
	&"plant.corn_machine_gun.attack_burst_count"
)

const SUPPORTED_ATTRIBUTES: Array[StringName] = [
	ATTRIBUTE_BUILDING_PHYSICAL_DEFENSE,
	ATTRIBUTE_PLAYER_MOVE_SPEED,
	ATTRIBUTE_GRASS_HEAL_MAX_HEALTH_RATIO,
	ATTRIBUTE_FENCE_MAX_HEALTH,
	ATTRIBUTE_FENCE_PHYSICAL_DEFENSE,
	ATTRIBUTE_AGAVE_CANNON_ATTACK_DAMAGE,
	ATTRIBUTE_CORN_MACHINE_GUN_BURST_COUNT,
]
const INTEGER_ATTRIBUTES: Array[StringName] = [
	ATTRIBUTE_BUILDING_PHYSICAL_DEFENSE,
	ATTRIBUTE_FENCE_MAX_HEALTH,
	ATTRIBUTE_FENCE_PHYSICAL_DEFENSE,
	ATTRIBUTE_AGAVE_CANNON_ATTACK_DAMAGE,
	ATTRIBUTE_CORN_MACHINE_GUN_BURST_COUNT,
]

@export var attribute_id: StringName = &""
@export var bonus: float = 0.0


func is_valid() -> bool:
	if (
		attribute_id not in SUPPORTED_ATTRIBUTES
		or not is_finite(bonus)
		or bonus <= 0.0
	):
		return false
	if (
		attribute_id in INTEGER_ATTRIBUTES
		and not is_equal_approx(bonus, float(roundi(bonus)))
	):
		return false
	return (
		attribute_id != ATTRIBUTE_GRASS_HEAL_MAX_HEALTH_RATIO
		or bonus <= 1.0
	)


func get_semantic_key() -> StringName:
	return StringName("additive:%s" % String(attribute_id))
