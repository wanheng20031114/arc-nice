extends PlantDefense
class_name AgaveCannon

const CANNONBALL_SCENE := preload("res://scene/plant_defense/agave_cannonball.tscn")
const WORLD_COLLISION_MASK := 1
const DEFAULT_ATTACK_DAMAGE := 25
const DEFAULT_ATTACK_RANGE := 176.0
const DEFAULT_ATTACK_INTERVAL := 2.0
const CANNONBALL_SPEED := 180.0
const CANNONBALL_EXPLOSION_RADIUS := 18.0
const FIRE_PROJECTILE_FRAME := 2
const IDLE_AIM_INTERVAL_MIN := 0.55
const IDLE_AIM_INTERVAL_MAX := 0.85
const IDLE_AIM_BURST_INTERVAL_MIN := 0.24
const IDLE_AIM_BURST_INTERVAL_MAX := 0.38
const IDLE_AIM_LIMIT := 0.26179939 # 15 degrees; 30 degrees across the full arc.
const IDLE_AIM_MIN_TARGET_OFFSET := 0.05235988 # 3 degrees from the center.

@onready var body_sprite: AnimatedSprite2D = $VisualRoot/BodySprite
@onready var cannon_pivot: Node2D = $VisualRoot/CannonPivot
@onready var cannon_sprite: AnimatedSprite2D = $VisualRoot/CannonPivot/CannonSprite
@onready var muzzle: Marker2D = $VisualRoot/CannonPivot/Muzzle
@onready var targeting_area: Area2D = $TargetingArea
@onready var targeting_shape: CollisionShape2D = $TargetingArea/CollisionShape2D
@onready var attack_timer: Timer = $AttackTimer
@onready var idle_aim_timer: Timer = $IdleAimTimer
@onready var health_bar: Control = $HealthBar
@onready var fire_audio: AudioStreamPlayer2D = $FireAudio

var target_candidates: Dictionary[int, Enemy] = {}
var pending_target: Enemy = null
var projectile_spawned_for_current_attack := false
var configured_attack_damage := DEFAULT_ATTACK_DAMAGE
var configured_attack_range := DEFAULT_ATTACK_RANGE
var idle_aim_random := RandomNumberGenerator.new()
var idle_aim_center_rotation := 0.0
var idle_aim_last_direction := 0
var idle_aim_single_moves_completed := 0
var idle_aim_burst_followup_pending := false
var idle_aim_active := false


func _on_setup_completed() -> void:
	super._on_setup_completed()
	configured_attack_damage = maxi(config.attack_damage, 0)
	configured_attack_range = maxf(config.attack_range, 0.0)

	var range_circle := targeting_shape.shape as CircleShape2D
	if range_circle != null:
		range_circle.radius = configured_attack_range
	# Target acquisition uses the runtime's shared spatial index. Keeping one
	# monitoring Area2D per cannon would multiply broad-phase overlap work by
	# every plant and every enemy in high-pressure waves.
	targeting_area.set_deferred("monitoring", false)
	targeting_area.set_deferred("monitorable", false)

	health_bar.call("setup", max_health, current_health)
	if not health_changed.is_connected(_on_health_changed):
		health_changed.connect(_on_health_changed)

	body_sprite.play(&"idle")
	cannon_sprite.play(&"idle")
	idle_aim_center_rotation = cannon_pivot.rotation
	idle_aim_random.randomize()
	_start_idle_aim()
	if is_multiplayer_proxy:
		_disable_proxy_combat_runtime()
		return
	var attack_interval := config.get_attack_interval()
	if attack_interval <= 0.0:
		attack_interval = DEFAULT_ATTACK_INTERVAL
	attack_timer.wait_time = attack_interval
	attack_timer.start()


func _on_multiplayer_proxy_configured() -> void:
	_disable_proxy_combat_runtime()


func _disable_proxy_combat_runtime() -> void:
	attack_timer.stop()
	targeting_area.set_deferred("monitoring", false)
	target_candidates.clear()
	pending_target = null
	projectile_spawned_for_current_attack = false
	cannon_sprite.play(&"idle")


func _on_death_started() -> void:
	attack_timer.stop()
	_stop_idle_aim()
	targeting_area.set_deferred("monitoring", false)
	target_candidates.clear()
	pending_target = null
	super._on_death_started()


func _on_health_changed(new_health: int, new_max_health: int) -> void:
	health_bar.call("set_health", new_health, new_max_health)


func _on_targeting_area_body_entered(body: Node2D) -> void:
	var enemy := body as Enemy
	if not _is_valid_target(enemy):
		return
	target_candidates[enemy.get_instance_id()] = enemy


func _on_targeting_area_body_exited(body: Node2D) -> void:
	var enemy := body as Enemy
	if enemy == null:
		return
	target_candidates.erase(enemy.get_instance_id())
	if pending_target == enemy:
		pending_target = null


func _on_attack_timer_timeout() -> void:
	if is_multiplayer_proxy or is_dead or cannon_sprite.animation == &"fire":
		return

	var target := _select_nearest_visible_enemy()
	if target == null:
		_start_idle_aim()
		return

	_stop_idle_aim()
	pending_target = target
	projectile_spawned_for_current_attack = false
	_point_cannon_at(target.global_position)
	cannon_sprite.play(&"fire")


func _on_cannon_sprite_frame_changed() -> void:
	if cannon_sprite.animation != &"fire":
		return
	if cannon_sprite.frame < FIRE_PROJECTILE_FRAME:
		return
	if projectile_spawned_for_current_attack:
		return

	projectile_spawned_for_current_attack = true
	_fire_pending_projectile()


func _on_cannon_sprite_animation_finished() -> void:
	if cannon_sprite.animation != &"fire":
		return
	pending_target = null
	projectile_spawned_for_current_attack = false
	cannon_sprite.play(&"idle")


func _on_idle_aim_timer_timeout() -> void:
	if not idle_aim_active or is_dead:
		return
	_apply_idle_aim_step()
	if idle_aim_burst_followup_pending:
		idle_aim_burst_followup_pending = false
		idle_aim_single_moves_completed = 0
		idle_aim_timer.start(_sample_idle_aim_interval(false))
	elif idle_aim_single_moves_completed >= 2:
		idle_aim_burst_followup_pending = true
		idle_aim_timer.start(_sample_idle_aim_interval(true))
	else:
		idle_aim_single_moves_completed += 1
		idle_aim_timer.start(_sample_idle_aim_interval(false))


func _start_idle_aim() -> void:
	if is_dead or idle_aim_active:
		return
	idle_aim_active = true
	idle_aim_last_direction = 0
	idle_aim_single_moves_completed = 0
	idle_aim_burst_followup_pending = false
	cannon_pivot.rotation = idle_aim_center_rotation
	idle_aim_timer.start(_sample_idle_aim_interval(false))


func _stop_idle_aim() -> void:
	idle_aim_timer.stop()
	idle_aim_active = false
	idle_aim_last_direction = 0
	idle_aim_single_moves_completed = 0
	idle_aim_burst_followup_pending = false


func _apply_idle_aim_step() -> void:
	var direction := -idle_aim_last_direction
	if direction == 0:
		direction = 1 if idle_aim_random.randi_range(0, 1) == 1 else -1
	# Alternating signed half-arcs guarantees that the actual rotation delta,
	# rather than only the requested direction, reverses on every idle move.
	var target_offset := idle_aim_random.randf_range(
		IDLE_AIM_MIN_TARGET_OFFSET,
		IDLE_AIM_LIMIT
	)
	cannon_pivot.rotation = idle_aim_center_rotation + target_offset * float(direction)
	idle_aim_last_direction = direction


func _sample_idle_aim_interval(is_burst_followup: bool) -> float:
	if is_burst_followup:
		return idle_aim_random.randf_range(
			IDLE_AIM_BURST_INTERVAL_MIN,
			IDLE_AIM_BURST_INTERVAL_MAX
		)
	return idle_aim_random.randf_range(IDLE_AIM_INTERVAL_MIN, IDLE_AIM_INTERVAL_MAX)


func set_idle_aim_random_seed(seed_value: int) -> void:
	idle_aim_random.seed = seed_value


func _fire_pending_projectile() -> void:
	if is_multiplayer_proxy:
		return
	if not _is_valid_target(pending_target):
		return
	if not _has_clear_world_line_to(pending_target):
		return

	_point_cannon_at(pending_target.global_position)
	var shot_direction := muzzle.global_position.direction_to(pending_target.global_position)
	if shot_direction == Vector2.ZERO:
		shot_direction = Vector2.RIGHT.rotated(cannon_pivot.global_rotation)

	var spawn_parent := get_tree().current_scene
	if spawn_parent == null:
		return

	var cannonball: AgaveCannonball = null
	if (
		spawn_parent.has_method("has_session_object_pool_scene")
		and bool(spawn_parent.call("has_session_object_pool_scene", CANNONBALL_SCENE))
	):
		cannonball = spawn_parent.call(
			"acquire_session_object",
			CANNONBALL_SCENE,
			false
		) as AgaveCannonball
	else:
		cannonball = CANNONBALL_SCENE.instantiate() as AgaveCannonball
	if cannonball == null:
		return
	cannonball.top_level = true
	if cannonball.get_parent() == null:
		spawn_parent.add_child(cannonball)
	cannonball.global_position = muzzle.global_position
	var projectile_lifetime := configured_attack_range / CANNONBALL_SPEED + 0.25
	cannonball.setup(
		shot_direction,
		configured_attack_damage,
		CANNONBALL_SPEED,
		CANNONBALL_EXPLOSION_RADIUS,
		projectile_lifetime,
		true,
		int(get_meta(&"net_id", get_instance_id()))
	)
	cannonball.reset_physics_interpolation()
	if spawn_parent.has_method("broadcast_plant_projectile_visual"):
		spawn_parent.call(
			"broadcast_plant_projectile_visual",
			int(get_meta(&"net_id", 0)),
			muzzle.global_position,
			shot_direction,
			CANNONBALL_SPEED,
			CANNONBALL_EXPLOSION_RADIUS,
			projectile_lifetime
		)
	if fire_audio.stream != null:
		fire_audio.play()


func _select_nearest_visible_enemy() -> Enemy:
	var nearest_enemy: Enemy = null
	var nearest_distance_squared := INF
	var stale_candidate_ids: Array[int] = []
	var candidates: Array[Enemy] = []
	var current_scene := get_tree().current_scene
	if current_scene != null and current_scene.has_method("query_combat_targets"):
		candidates.assign(
			current_scene.call(
				"query_combat_targets",
				global_position,
				configured_attack_range,
				0
			) as Array
		)
	else:
		for candidate_id: int in target_candidates:
			var fallback_candidate := target_candidates[candidate_id] as Enemy
			if not _is_valid_target(fallback_candidate):
				stale_candidate_ids.append(candidate_id)
				continue
			candidates.append(fallback_candidate)

	for candidate in candidates:
		if not _is_valid_target(candidate):
			continue
		var candidate_id := candidate.get_instance_id()
		var distance_squared := global_position.distance_squared_to(candidate.global_position)
		if distance_squared > configured_attack_range * configured_attack_range:
			continue
		if not _has_clear_world_line_to(candidate):
			continue
		if (
			distance_squared < nearest_distance_squared
			or (
				is_equal_approx(distance_squared, nearest_distance_squared)
				and (nearest_enemy == null or candidate_id < nearest_enemy.get_instance_id())
			)
		):
			nearest_enemy = candidate
			nearest_distance_squared = distance_squared

	for stale_id: int in stale_candidate_ids:
		target_candidates.erase(stale_id)

	return nearest_enemy


func _is_valid_target(enemy: Enemy) -> bool:
	return (
		enemy != null
		and is_instance_valid(enemy)
		and enemy.is_inside_tree()
		and not enemy.is_dead
	)


func _has_clear_world_line_to(enemy: Enemy) -> bool:
	if not _is_valid_target(enemy):
		return false
	var query := PhysicsRayQueryParameters2D.create(
		cannon_pivot.global_position,
		enemy.global_position,
		WORLD_COLLISION_MASK,
		[get_rid()]
	)
	query.collide_with_bodies = true
	query.collide_with_areas = false
	return get_world_2d().direct_space_state.intersect_ray(query).is_empty()


func _point_cannon_at(world_position: Vector2) -> void:
	var aim_direction := cannon_pivot.global_position.direction_to(world_position)
	if aim_direction != Vector2.ZERO:
		cannon_pivot.global_rotation = aim_direction.angle() - muzzle.position.angle()
