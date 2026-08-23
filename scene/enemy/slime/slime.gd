extends YuanshiInsect
class_name Slime

const FIRE_TOUCH_SOURCE_FAMILY := CombatAttackRegistry.FIRE_SLIME_TOUCH
const FROST_TOUCH_SOURCE_TYPE := CombatAttackRegistry.FROST_SLIME_TOUCH


func supports_layered_area_authoritative_simulation() -> bool:
	return false


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


func _on_touch_damage_applied(
	target: Node,
	source_snapshot: DamageSourceSnapshot
) -> void:
	match _get_slime_variant():
		SlimeConfig.Variant.FIRE:
			_apply_fire_status(target, source_snapshot)
		SlimeConfig.Variant.FROST:
			_apply_frost_status(target)


func _apply_fire_status(
	target: Node,
	source_snapshot: DamageSourceSnapshot
) -> void:
	var player := target as Player
	if player != null:
		if not player.is_dead:
			player.apply_burn_status(
				FIRE_TOUCH_SOURCE_FAMILY,
				CombatAttackRegistry.get_burn_duration(FIRE_TOUCH_SOURCE_FAMILY),
				CombatAttackRegistry.get_burn_tick_damage(FIRE_TOUCH_SOURCE_FAMILY),
				source_snapshot
			)
		return
	var plant := target as PlantDefense
	if plant != null and not plant.is_dead and not plant.is_removing:
		plant.apply_burn_status(
			FIRE_TOUCH_SOURCE_FAMILY,
			CombatAttackRegistry.get_burn_duration(FIRE_TOUCH_SOURCE_FAMILY),
			CombatAttackRegistry.get_burn_tick_damage(FIRE_TOUCH_SOURCE_FAMILY),
			source_snapshot
		)
		return
	var enemy := target as Enemy
	if enemy != null and not enemy.is_dead:
		enemy.apply_burn_status(
			FIRE_TOUCH_SOURCE_FAMILY,
			CombatAttackRegistry.get_burn_duration(FIRE_TOUCH_SOURCE_FAMILY),
			CombatAttackRegistry.get_burn_tick_damage(FIRE_TOUCH_SOURCE_FAMILY),
			source_snapshot
		)


func _apply_frost_status(target: Node) -> void:
	var player := target as Player
	if player != null and not player.is_dead:
		player.apply_cold_status()
		return
	var enemy := target as Enemy
	if enemy != null and not enemy.is_dead:
		enemy.apply_cold_status()
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
