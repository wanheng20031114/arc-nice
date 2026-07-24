extends YuanshiInsect
class_name Slime

const FIRE_TOUCH_SOURCE_FAMILY := &"fire_slime_touch"
const FROST_TOUCH_SOURCE_TYPE := &"frost_slime_touch"
const ELEMENTAL_STATUS_DURATION_SECONDS := 3.0
const FIRE_BURN_LEVEL := 10


func _get_touch_damage_type() -> EnemyConfig.DamageType:
	if _is_elemental_variant():
		return EnemyConfig.DamageType.MAGIC
	return EnemyConfig.DamageType.PHYSICAL


func _get_multiplayer_touch_source_type() -> StringName:
	match _get_slime_variant():
		SlimeConfig.Variant.FIRE:
			return FIRE_TOUCH_SOURCE_FAMILY
		SlimeConfig.Variant.FROST:
			return FROST_TOUCH_SOURCE_TYPE
		_:
			return &"enemy_touch"


func _on_touch_damage_applied(target: Node) -> void:
	match _get_slime_variant():
		SlimeConfig.Variant.FIRE:
			_apply_fire_status(target)
		SlimeConfig.Variant.FROST:
			_apply_frost_status(target)


func _apply_fire_status(target: Node) -> void:
	var player := target as Player
	if player != null:
		if not player.is_dead:
			player.apply_burn_status(
				FIRE_TOUCH_SOURCE_FAMILY,
				ELEMENTAL_STATUS_DURATION_SECONDS,
				FIRE_BURN_LEVEL
			)
		return
	var plant := target as PlantDefense
	if plant != null and not plant.is_dead and not plant.is_removing:
		plant.apply_burn_status(
			FIRE_TOUCH_SOURCE_FAMILY,
			ELEMENTAL_STATUS_DURATION_SECONDS,
			FIRE_BURN_LEVEL
		)


func _apply_frost_status(target: Node) -> void:
	var player := target as Player
	if player != null and not player.is_dead:
		player.apply_cold_status()
	# Plants receive the direct magic damage, but movement frost has no useful
	# meaning for an immobile building and PlantDefense has no cold runtime.


func _is_elemental_variant() -> bool:
	var slime_variant := _get_slime_variant()
	return (
		slime_variant == SlimeConfig.Variant.FIRE
		or slime_variant == SlimeConfig.Variant.FROST
	)


func _get_slime_variant() -> SlimeConfig.Variant:
	var slime_config := config as SlimeConfig
	if slime_config == null:
		return SlimeConfig.Variant.BASIC
	return slime_config.variant
