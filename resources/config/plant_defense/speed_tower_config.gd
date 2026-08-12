extends PlantDefenseConfig
class_name SpeedTowerConfig

@export_group("移速强化")
@export_range(0.0, 1000.0, 1.0, "or_greater") var move_speed_bonus := 10.0


func is_valid() -> bool:
	return (
		super.is_valid()
		and building_category == BuildingCategory.SUPPORT_TOWER
		and footprint_size == Vector2i(2, 2)
		and is_finite(move_speed_bonus)
		and move_speed_bonus > 0.0
	)
