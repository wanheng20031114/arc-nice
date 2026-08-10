extends CapooKnight
class_name CardboardMonster


func _physics_process(delta: float) -> void:
	_update_touch_damage(delta)
	super._physics_process(delta)


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
