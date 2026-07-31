extends Bullet
class_name TangoLaserBullet

const MAX_COMPENSATION_STEP := 1.0 / 60.0
const COLLISION_EPSILON := 0.01

@onready var sweep_cast: ShapeCast2D = $ShapeCast2D
@onready var bullet_sprite: AnimatedSprite2D = $AnimatedSprite2D


func _ready() -> void:
	super._ready()
	_play_flight_animation()


func on_pool_acquired(generation: int) -> void:
	super.on_pool_acquired(generation)
	# Tango bullets use the authored ShapeCast sweep exclusively. Keeping the
	# Area2D monitor disabled avoids adding three high-frequency overlap pairs per
	# volley while retaining the root collision layer for projectile interactions.
	monitoring = false
	monitorable = false
	if sweep_cast != null:
		sweep_cast.clear_exceptions()
	_play_flight_animation()


func on_pool_released(generation: int) -> void:
	if sweep_cast != null:
		sweep_cast.clear_exceptions()
	if bullet_sprite != null:
		bullet_sprite.stop()
	super.on_pool_released(generation)


func clamp_spawn_position_to_clear_path(
	path_origin: Vector2,
	intended_spawn_position: Vector2,
	excluded_collider: CollisionObject2D = null
) -> Vector2:
	if sweep_cast == null:
		return intended_spawn_position
	if excluded_collider != null:
		sweep_cast.add_exception(excluded_collider)
	var spawn_segment := intended_spawn_position - path_origin
	var segment_length := spawn_segment.length()
	if segment_length <= COLLISION_EPSILON:
		return intended_spawn_position

	# The three authored muzzles sit beyond Tango's body. Sweep that otherwise
	# skipped segment before placing the projectile so a close wall cannot be
	# bypassed simply because the visual cannon is already on its far side.
	var previous_position := global_position
	var previous_rotation := rotation
	var previous_target := sweep_cast.target_position
	global_position = path_origin
	rotation = spawn_segment.angle()
	sweep_cast.target_position = Vector2(segment_length, 0.0)
	sweep_cast.force_shapecast_update()

	var clear_distance := segment_length
	var path_blocked := sweep_cast.is_colliding()
	if path_blocked:
		clear_distance *= clampf(
			sweep_cast.get_closest_collision_safe_fraction(),
			0.0,
			1.0
		)

	global_position = previous_position
	rotation = previous_rotation
	sweep_cast.target_position = previous_target
	if not path_blocked:
		return intended_spawn_position
	return path_origin + spawn_segment / segment_length * maxf(
		clear_distance - COLLISION_EPSILON,
		0.0
	)


func _physics_process(delta: float) -> void:
	if not pool_active:
		return
	if remaining_lifetime <= 0.0:
		retire()
		return
	var safe_delta := maxf(delta, 0.0)
	var simulated_delta := minf(safe_delta, remaining_lifetime)
	_sweep_segment(simulated_delta)
	remaining_lifetime -= safe_delta
	if remaining_lifetime <= 0.0 and pool_active:
		retire()


func simulate_compensated_motion(seconds: float) -> void:
	var time_left := clampf(seconds, 0.0, max_lifetime)
	while time_left > 0.0 and pool_active:
		var step := minf(time_left, MAX_COMPENSATION_STEP)
		_sweep_segment(step)
		time_left -= step


func _sweep_segment(delta: float) -> void:
	if delta <= 0.0 or not pool_active:
		return
	_update_homing(delta)
	var remaining_distance := maxf(speed, 0.0) * delta
	if remaining_distance <= 0.0:
		return
	rotation = direction.angle()
	var collision_budget := maxi(sweep_cast.max_results, 1)
	while remaining_distance > COLLISION_EPSILON and collision_budget > 0:
		var sweep_start := global_position
		sweep_cast.target_position = Vector2(remaining_distance, 0.0)
		sweep_cast.force_shapecast_update()
		var hits := _collect_sorted_sweep_hits(sweep_start, remaining_distance)
		if hits.is_empty():
			global_position = sweep_start + direction * remaining_distance
			return

		var nearest_distance := remaining_distance
		for hit in hits:
			var collider := hit["collider"] as Node
			var hit_position := hit["position"] as Vector2
			var forward_distance := float(hit["distance"])
			nearest_distance = minf(nearest_distance, forward_distance)
			var enemy := collider as Enemy
			if enemy == null:
				global_position = sweep_start + direction * maxf(
					forward_distance - COLLISION_EPSILON,
					0.0
				)
				retire()
				return

			sweep_cast.add_exception(enemy)
			global_position = hit_position
			try_hit_enemy(enemy)
			collision_budget -= 1
			if not pool_active:
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
	if remaining_distance > 0.0 and collision_budget > 0 and pool_active:
		global_position += direction * remaining_distance


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
		return not (a["collider"] is Enemy) and b["collider"] is Enemy
	)
	return hits


func _play_flight_animation() -> void:
	if bullet_sprite == null:
		return
	bullet_sprite.play(&"fly")
	bullet_sprite.frame = 0
	bullet_sprite.frame_progress = 0.0
