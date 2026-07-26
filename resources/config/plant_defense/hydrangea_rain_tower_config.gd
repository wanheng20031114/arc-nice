extends PlantDefenseConfig
class_name HydrangeaRainTowerConfig

const RAIN_EMISSION_START_DELAY_SECONDS := 0.24
const RAIN_DROP_FALL_SECONDS := 0.44
const EFFECT_START_DELAY_SECONDS := (
	RAIN_EMISSION_START_DELAY_SECONDS + RAIN_DROP_FALL_SECONDS
)

@export_group("雨幕技能")
@export_range(0.1, 120.0, 0.1, "or_greater") var rain_interval_seconds := 6.0
@export_range(0.1, 30.0, 0.1, "or_greater") var rain_duration_seconds := 1.5
@export_range(0.1, 30.0, 0.1, "or_greater") var effect_duration_seconds := 5.0
@export_range(0.1, 10.0, 0.1, "or_greater") var rain_tick_interval_seconds := 1.0
@export_range(0, 9999, 1, "or_greater") var healing_per_tick := 50
@export_range(0, 9999, 1, "or_greater") var magic_damage_per_tick := 5
@export_range(0.0, 1.0, 0.05) var enemy_attack_damage_multiplier := 0.8
@export_range(0.1, 64.0, 0.1, "or_greater") var target_search_radius_cells := 12.0
@export_range(1.0, 2048.0, 1.0, "or_greater") var rain_radius := 48.0


func is_valid() -> bool:
	return (
		super.is_valid()
		and is_finite(rain_interval_seconds)
		and rain_interval_seconds > 0.0
		and is_finite(rain_duration_seconds)
		and rain_duration_seconds > RAIN_EMISSION_START_DELAY_SECONDS
		and is_finite(effect_duration_seconds)
		and effect_duration_seconds >= rain_duration_seconds
		and rain_interval_seconds
		>= EFFECT_START_DELAY_SECONDS + effect_duration_seconds
		and is_finite(rain_tick_interval_seconds)
		and rain_tick_interval_seconds > 0.0
		and rain_tick_interval_seconds <= effect_duration_seconds
		and healing_per_tick > 0
		and magic_damage_per_tick > 0
		and enemy_attack_damage_multiplier > 0.0
		and enemy_attack_damage_multiplier <= 1.0
		and is_finite(target_search_radius_cells)
		and target_search_radius_cells > 0.0
		and is_finite(rain_radius)
		and rain_radius > 0.0
	)
