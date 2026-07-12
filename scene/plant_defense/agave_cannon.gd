extends PlantDefense
class_name AgaveCannon

const CANNONBALL_SCENE := preload("res://scene/plant_defense/agave_cannonball.tscn")
const WORLD_COLLISION_MASK := 1
const DEFAULT_ATTACK_DAMAGE := 50
const DEFAULT_ATTACK_RANGE := 176.0
const DEFAULT_ATTACK_INTERVAL := 2.0
const CANNONBALL_SPEED := 180.0
const CANNONBALL_EXPLOSION_RADIUS := 18.0
const FIRE_PROJECTILE_FRAME := 2

@onready var body_sprite: AnimatedSprite2D = $BodySprite
@onready var cannon_pivot: Node2D = $CannonPivot
@onready var cannon_sprite: AnimatedSprite2D = $CannonPivot/CannonSprite
@onready var muzzle: Marker2D = $CannonPivot/Muzzle
@onready var targeting_area: Area2D = $TargetingArea
@onready var targeting_shape: CollisionShape2D = $TargetingArea/CollisionShape2D
@onready var attack_timer: Timer = $AttackTimer
@onready var health_bar: Control = $HealthBar
@onready var fire_audio: AudioStreamPlayer2D = $FireAudio

var target_candidates: Dictionary[int, Enemy] = {}
var pending_target: Enemy = null
var projectile_spawned_for_current_attack := false
var configured_attack_damage := DEFAULT_ATTACK_DAMAGE
var configured_attack_range := DEFAULT_ATTACK_RANGE


func _on_setup_completed() -> void:
	super._on_setup_completed()
	configured_attack_damage = maxi(config.attack_damage, 0)
	configured_attack_range = maxf(config.attack_range, 0.0)

	var range_circle := targeting_shape.shape as CircleShape2D
	if range_circle != null:
		range_circle.radius = configured_attack_range

	health_bar.call("setup", max_health, current_health)
	if not health_changed.is_connected(_on_health_changed):
		health_changed.connect(_on_health_changed)

	body_sprite.play(&"idle")
	cannon_sprite.play(&"idle")
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
		return

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

	var cannonball := CANNONBALL_SCENE.instantiate() as AgaveCannonball
	if cannonball == null:
		return
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

	for candidate_id: int in target_candidates:
		var candidate := target_candidates[candidate_id]
		if not _is_valid_target(candidate):
			stale_candidate_ids.append(candidate_id)
			continue
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
		cannon_pivot.global_rotation = aim_direction.angle()
