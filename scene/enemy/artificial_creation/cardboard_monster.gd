extends CapooKnight
class_name CardboardMonster


func supports_centralized_authoritative_simulation() -> bool:
	return true


func supports_layered_area_authoritative_simulation() -> bool:
	return true


# The authored touch-before-Knight ordering and single-shape proxy closure are
# covered by capoo_knight_layered_semantics_regression.gd.
func supports_layered_contact_authoritative_simulation() -> bool:
	return true


func supports_indexed_touch_authority() -> bool:
	return true


func _run_authoritative_physics_step(delta: float) -> void:
	_update_touch_damage(delta)
	super._run_authoritative_physics_step(delta)


func _layered_area_touch_damage_precedes_family_event() -> bool:
	return true


func _advances_layered_area_touch_damage_event() -> bool:
	return true


func _uses_inherited_touch_damage() -> bool:
	return true


func _uses_contact_shape_slash_reach() -> bool:
	return true


func _get_slash_damage_source_type() -> StringName:
	return &"cardboard_monster_slash"


func _create_damage_target_profile() -> DamageTargetProfile:
	var profile := super._create_damage_target_profile()
	profile.fixed_damage_per_accepted_hit = 1.0
	return profile
