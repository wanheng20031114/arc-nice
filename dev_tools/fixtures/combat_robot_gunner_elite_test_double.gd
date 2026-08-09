extends CombatRobotGunner

## Scheduler-only test seam. The production state machine still owns cadence,
## successful-shot accounting, movement, animation phase and cooldown changes.
## This override removes runtime/pool/network dependencies from the focused
## elite-config test while reporting exactly what every accepted shot would use.
var accepted_shots: Array[Dictionary] = []


func _fire_locked_bullet() -> bool:
	if gunner_config_cache == null:
		return false
	accepted_shots.append({
		"projectile_type": gunner_config_cache.projectile_type,
		"projectile_scene": gunner_config_cache.projectile_scene,
		"damage": get_effective_attack_damage(gunner_config_cache.attack_damage),
		"speed": gunner_config_cache.projectile_speed,
		"lifetime": gunner_config_cache.projectile_lifetime,
	})
	return true
