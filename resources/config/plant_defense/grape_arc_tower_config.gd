extends PlantDefenseConfig
class_name GrapeArcTowerConfig

@export_group("连锁电弧")
@export_range(1, 8, 1, "or_greater") var max_chain_targets := 4
@export_range(1.0, 512.0, 1.0, "or_greater") var chain_jump_range := 72.0
@export_range(0.05, 3.0, 0.01, "or_greater") var charge_seconds := 0.42


func is_valid() -> bool:
	return (
		super.is_valid()
		and attack_damage > 0
		and attack_range > 0.0
		and attack_speed > 0.0
		and max_chain_targets > 0
		and is_finite(chain_jump_range)
		and chain_jump_range > 0.0
		and is_finite(charge_seconds)
		and charge_seconds > 0.0
		and charge_seconds < get_attack_interval()
	)
