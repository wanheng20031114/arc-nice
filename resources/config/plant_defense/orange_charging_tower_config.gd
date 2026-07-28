extends PlantDefenseConfig
class_name OrangeChargingTowerConfig

@export_group("橘色充能气场")
@export_range(1, 8, 1, "or_greater") var aura_margin_cells: int = 1
@export_range(0.0, 10.0, 0.05, "or_greater") var player_skill_charge_bonus_per_second: float = 0.5
@export_range(0.05, 1.0, 0.05) var defense_attack_interval_multiplier: float = 0.8
@export_range(0.05, 1.0, 0.05) var production_duration_multiplier: float = 0.8


func is_valid() -> bool:
	return (
		super.is_valid()
		and building_category == BuildingCategory.SUPPORT_TOWER
		and footprint_size == Vector2i(2, 2)
		and aura_margin_cells > 0
		and is_finite(player_skill_charge_bonus_per_second)
		and player_skill_charge_bonus_per_second > 0.0
		and is_finite(defense_attack_interval_multiplier)
		and defense_attack_interval_multiplier > 0.0
		and defense_attack_interval_multiplier <= 1.0
		and is_finite(production_duration_multiplier)
		and production_duration_multiplier > 0.0
		and production_duration_multiplier <= 1.0
	)
