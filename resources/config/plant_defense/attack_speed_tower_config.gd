extends PlantDefenseConfig
class_name AttackSpeedTowerConfig

@export_group("攻速强化")
@export_range(0.01, 10.0, 0.01, "or_greater") var attack_speed_bonus_ratio := 0.03


func is_valid() -> bool:
	return (
		super.is_valid()
		and building_category == BuildingCategory.SUPPORT_TOWER
		and footprint_size == Vector2i(2, 2)
		and is_finite(attack_speed_bonus_ratio)
		and attack_speed_bonus_ratio > 0.0
	)
