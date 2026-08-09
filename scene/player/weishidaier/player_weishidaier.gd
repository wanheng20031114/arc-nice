extends AmmoRangedPlayer
class_name PlayerWeishidaier

const SKILL1_BOMB_SCENE := preload(
	"res://scene/player/weishidaier/weishidaier_skill1_bomb.tscn"
)

@export_group("Weishidaier Skill")
@export_range(0.0, 256.0, 0.1, "or_greater") var skill1_bomb_spawn_distance: float = 18.0


func _init() -> void:
	character_id = &"weishidaier"


func _get_skill1_direction() -> Vector2:
	if last_attack_direction != Vector2.ZERO:
		return last_attack_direction.normalized()
	return _facing_suffix_to_vector(facing_suffix)


func _try_use_skill1() -> bool:
	if not skill1_unlocked:
		return false
	if is_dead or are_combat_actions_locked():
		return false
	_sync_skill1_charge_duration_to_upgrade_level()
	if not has_void_battery_charge() and skill1_charge < skill1_charge_duration:
		return false

	var spawn_parent := _get_combat_spawn_parent()
	if spawn_parent == null:
		return false
	if _requires_multiplayer_gameplay_gateway() and gameplay_gateway == null:
		return false
	var bomb := SKILL1_BOMB_SCENE.instantiate() as WeishidaierSkill1Bomb
	if bomb == null:
		return false

	var shoot_direction := _get_skill1_direction()
	bomb.top_level = true
	bomb.bind_gameplay_context(combat_runtime, gameplay_gateway)
	var bomb_damage := get_skill1_projectile_damage()
	bomb.setup(self, shoot_direction, bomb_damage)
	var defer_void_battery_consumption := (
		gameplay_gateway != null and gameplay_gateway.is_client_view()
	)
	if not try_begin_skill1_activation(
		_uses_authoritative_skill_preserve_roll(),
		defer_void_battery_consumption,
		bomb.get_instance_id()
	):
		bomb.free()
		return false
	spawn_parent.add_child(bomb)
	bomb.global_position = global_position + shoot_direction * skill1_bomb_spawn_distance
	_register_multiplayer_projectile(
		bomb,
		&"skill1_bomb",
		bomb.global_position,
		shoot_direction,
		bomb_damage,
		bomb.speed,
		bomb.max_lifetime
	)
	_activate_collectible_skill_effects()
	_play_reload_audio()
	return true


func get_skill1_projectile_damage() -> int:
	return get_outgoing_damage(
		floori(float(attack_damage) * 3.3),
		EnemyConfig.DamageType.PHYSICAL
	)


func can_request_multiplayer_projectile(projectile_type: StringName) -> bool:
	return (
		super.can_request_multiplayer_projectile(projectile_type)
		or (
			projectile_type == &"skill1_bomb"
			and not is_dead
			and not are_combat_actions_locked()
		)
	)


func get_multiplayer_projectile_spawn_distance(projectile_type: StringName) -> float:
	if projectile_type == &"skill1_bomb":
		return skill1_bomb_spawn_distance
	return super.get_multiplayer_projectile_spawn_distance(projectile_type)
