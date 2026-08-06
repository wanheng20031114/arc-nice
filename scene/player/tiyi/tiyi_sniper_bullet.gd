extends Bullet
class_name TiyiSniperBullet

const HIT_EFFECT_SCENE := preload(
	"res://scene/player/tiyi/tiyi_sniper_hit_effect.tscn"
)
const MAX_COMPENSATION_STEP := 1.0 / 60.0
const COLLISION_EPSILON := 0.01
const WORLD_ENEMY_AND_PROJECTILE_SHIELD_MASK := 1 | 4 | (1 << 12)

@onready var sweep_cast: ShapeCast2D = $ShapeCast2D
@onready var bullet_sprite: AnimatedSprite2D = $BulletSprite

var _confirmed_hit_keys: Dictionary = {}
var _temporary_shield_exceptions: Array[ProjectileShieldArea] = []


func _ready() -> void:
	super._ready()
	sweep_cast.collision_mask = WORLD_ENEMY_AND_PROJECTILE_SHIELD_MASK
	sweep_cast.collide_with_bodies = true
	sweep_cast.collide_with_areas = true
	if bullet_sprite != null:
		bullet_sprite.play(&"fly")


func on_pool_acquired(generation: int) -> void:
	super.on_pool_acquired(generation)
	_confirmed_hit_keys.clear()
	_clear_temporary_shield_exceptions()


func on_pool_released(generation: int) -> void:
	_clear_temporary_shield_exceptions()
	_confirmed_hit_keys.clear()
	super.on_pool_released(generation)


func get_damage_type() -> EnemyConfig.DamageType:
	return EnemyConfig.DamageType.MAGIC


func _physics_process(delta: float) -> void:
	if not pool_active:
		return
	if remaining_lifetime <= 0.0:
		retire()
		return
	var simulated_delta := minf(maxf(delta, 0.0), remaining_lifetime)
	_sweep_segment(simulated_delta)
	remaining_lifetime -= maxf(delta, 0.0)
	if remaining_lifetime <= 0.0 and pool_active:
		retire()


func simulate_compensated_motion(seconds: float) -> void:
	var time_left := clampf(seconds, 0.0, max_lifetime)
	while time_left > 0.0 and pool_active and not is_queued_for_deletion():
		var step := minf(time_left, MAX_COMPENSATION_STEP)
		_sweep_segment(step)
		time_left -= step


func _sweep_segment(delta: float) -> void:
	if delta <= 0.0 or not pool_active or is_queued_for_deletion():
		return
	_update_homing(delta)
	var remaining_distance := maxf(speed, 0.0) * delta
	if remaining_distance <= 0.0:
		return
	rotation = direction.angle()
	var collision_budget := maxi(sweep_cast.max_results, 1)
	_clear_temporary_shield_exceptions()
	while remaining_distance > COLLISION_EPSILON and collision_budget > 0:
		var sweep_start := global_position
		sweep_cast.target_position = Vector2(remaining_distance, 0.0)
		sweep_cast.force_shapecast_update()
		var hits := _collect_sorted_sweep_hits(sweep_start, remaining_distance)
		if hits.is_empty():
			global_position = sweep_start + direction * remaining_distance
			_clear_temporary_shield_exceptions()
			return

		var nearest_distance := remaining_distance
		for hit in hits:
			var collider := hit["collider"] as Node
			var hit_position := hit["position"] as Vector2
			var forward_distance := float(hit["distance"])
			nearest_distance = minf(nearest_distance, forward_distance)
			var shield := collider as ProjectileShieldArea
			if shield != null:
				global_position = hit_position
				if shield.try_intercept(direction):
					_clear_temporary_shield_exceptions()
					retire()
					return
				if not _temporary_shield_exceptions.has(shield):
					sweep_cast.add_exception(shield)
					_temporary_shield_exceptions.append(shield)
				collision_budget -= 1
				if collision_budget <= 0:
					break
				continue
			var enemy := collider as Enemy
			if enemy == null:
				global_position = sweep_start + direction * maxf(
					forward_distance - COLLISION_EPSILON,
					0.0
				)
				_clear_temporary_shield_exceptions()
				retire()
				return

			# A ShapeCast stops at its earliest unsafe fraction. Piercing therefore
			# resumes a new cast after each contact and excludes already-hit bodies.
			sweep_cast.add_exception(enemy)
			global_position = hit_position
			try_hit_enemy(enemy)
			collision_budget -= 1
			if not pool_active or is_queued_for_deletion():
				_clear_temporary_shield_exceptions()
				return
			if collision_budget <= 0:
				break

		var advance_distance := clampf(
			nearest_distance + COLLISION_EPSILON,
			COLLISION_EPSILON,
			remaining_distance
		)
		global_position = sweep_start + direction * advance_distance
		remaining_distance -= advance_distance
	if (
		remaining_distance > 0.0
		and collision_budget > 0
		and pool_active
		and not is_queued_for_deletion()
	):
		global_position += direction * remaining_distance
	_clear_temporary_shield_exceptions()


func _clear_temporary_shield_exceptions() -> void:
	for shield in _temporary_shield_exceptions:
		if shield != null and is_instance_valid(shield):
			sweep_cast.remove_exception(shield)
	_temporary_shield_exceptions.clear()


func _collect_sorted_sweep_hits(
	sweep_start: Vector2,
	travel_distance: float
) -> Array[Dictionary]:
	var hits: Array[Dictionary] = []
	var seen_colliders: Dictionary = {}
	for result_index in range(sweep_cast.get_collision_count()):
		var collider := sweep_cast.get_collider(result_index)
		if collider == null or not is_instance_valid(collider):
			continue
		var collider_id := collider.get_instance_id()
		if seen_colliders.has(collider_id):
			continue
		seen_colliders[collider_id] = true
		var hit_position := sweep_cast.get_collision_point(result_index)
		var forward_distance := clampf(
			(hit_position - sweep_start).dot(direction),
			0.0,
			travel_distance
		)
		hits.append({
			"collider": collider,
			"position": hit_position,
			"distance": forward_distance,
		})
	hits.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		var distance_a := float(a["distance"])
		var distance_b := float(b["distance"])
		if not is_equal_approx(distance_a, distance_b):
			return distance_a < distance_b
		# 同距离时墙体优先，避免处于墙后的目标在边界处先结算。
		return not (a["collider"] is Enemy) and b["collider"] is Enemy
	)
	return hits


func try_hit_enemy(enemy: Enemy) -> bool:
	if enemy == null or not is_instance_valid(enemy):
		return false
	var registered := super.try_hit_enemy(enemy)
	if not registered:
		return false
	if _should_play_local_authoritative_hit_effect():
		var enemy_net_id := int(enemy.get_meta("net_id", 0))
		var hit_key: Variant = enemy_net_id if enemy_net_id > 0 else enemy.get_instance_id()
		_spawn_hit_effect_once(hit_key, global_position, direction)
	return true


func apply_authoritative_hit_confirmation(
	enemy_net_id: int,
	hit_position: Vector2,
	hit_direction: Vector2,
	continues_piercing: bool
) -> void:
	global_position = hit_position
	if hit_direction != Vector2.ZERO:
		direction = hit_direction.normalized()
		rotation = direction.angle()
	var hit_key: Variant = enemy_net_id if enemy_net_id > 0 else "%s:%s" % [hit_position.x, hit_position.y]
	_spawn_hit_effect_once(hit_key, hit_position, direction)
	if not continues_piercing and pool_active and not is_queued_for_deletion():
		retire()


func _should_play_local_authoritative_hit_effect() -> bool:
	return (
		combat_runtime != null
		and is_instance_valid(combat_runtime)
		and combat_runtime.runtime_mode != CombatRuntimeBase.RuntimeMode.CLIENT_VIEW
	)


func _spawn_hit_effect_once(
	hit_key: Variant,
	hit_position: Vector2,
	hit_direction: Vector2
) -> void:
	if _confirmed_hit_keys.has(hit_key):
		return
	_confirmed_hit_keys[hit_key] = true
	var spawn_parent := combat_runtime
	if spawn_parent != null and not is_instance_valid(spawn_parent):
		spawn_parent = null
	if spawn_parent == null:
		return
	var effect := HIT_EFFECT_SCENE.instantiate() as TiyiSniperHitEffect
	if effect == null:
		return
	effect.top_level = true
	effect.setup(hit_direction)
	spawn_parent.add_child(effect)
	effect.global_position = hit_position
