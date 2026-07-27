extends RefCounted
class_name DamageTargetProfile

## Target-owned signed-int64 numeric inputs. Entity-specific rules (directional modifiers,
## strongest reduction, status multipliers) are reduced to these explicit
## stages before the pure resolver runs.
var current_health: int = 0
var physical_defense: int = 0
var magic_defense: int = 0
var minimum_damage: int = 1
var pre_mitigation_multiplier: float = 1.0
var pre_multiplier_rounding: int = CombatTypes.RoundingMode.NEAREST
var post_mitigation_multiplier: float = 1.0
var post_multiplier_rounding: int = CombatTypes.RoundingMode.NEAREST


func _init(
	initial_current_health: int = 0,
	initial_physical_defense: int = 0,
	initial_magic_defense: int = 0
) -> void:
	current_health = maxi(initial_current_health, 0)
	physical_defense = maxi(initial_physical_defense, 0)
	magic_defense = clampi(initial_magic_defense, 0, 100)
