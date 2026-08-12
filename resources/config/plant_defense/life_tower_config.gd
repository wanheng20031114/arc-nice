extends PlantDefenseConfig
class_name LifeTowerConfig

@export_group("生命强化")
@export_range(0.01, 10.0, 0.01, "or_greater") var max_health_bonus_ratio := 0.10


func is_valid() -> bool:
	return (
		super.is_valid()
		and building_category == BuildingCategory.SUPPORT_TOWER
		and footprint_size == Vector2i(2, 2)
		and is_finite(max_health_bonus_ratio)
		and max_health_bonus_ratio > 0.0
	)
