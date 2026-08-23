extends Area2D
class_name CapooAK47Bullet

signal projectile_finished(projectile_id: int, projectile: Node)

const WORLD_COLLISION_MASK := 1
const DAMAGEABLE_COLLISION_MASK := 2 | 4 | 512
const WORLD_COLLISION_CHECK_INTERVAL_FRAMES := 2
const HIT_EFFECT_SCENE := preload("res://scene/combat/projectiles/bullet_hit_effect.tscn")
const WORLD_EFFECT_VISIBILITY := preload("res://scene/combat/feedback/world_effect_visibility.gd")

static var world_collision_certificate_enabled := false
static var batched_motion_enabled := true
static var performance_metrics_enabled := false
static var _performance_metrics := {
	"world_segment_calls": 0,
	"certified_clear_calls": 0,
	"physics_ray_calls": 0,
	"physics_ray_hits": 0,
	"world_segment_usec": 0,
}

@export var speed: float = 142.5
@export var max_lifetime: float = 2.0

@onready var animated_sprite: AnimatedSprite2D = $AnimatedSprite2D

var direction := Vector2.RIGHT
var damage: int = 1
var remaining_lifetime: float = 0.0
var has_hit: bool = false
var projectile_id: int = 0
var owner_peer_id: int = 0
var source_type: StringName = &"capoo_ak47_bullet"
var damage_source_snapshot: DamageSourceSnapshot = null
var pool_active: bool = true
var combat_runtime: CombatRuntimeBase = null
var gameplay_gateway: MultiplayerGameplayGateway = null
var _authored_speed: float = 142.5
var _authored_max_lifetime: float = 2.0
var _authored_collision_layer: int = 128
var _authored_collision_mask: int = DAMAGEABLE_COLLISION_MASK
var world_collision_pathfinder: GridPathfinder = null
var batched_motion_system = null
var requested_batched_motion_system: Node = null
var batched_activation_physics_frame := -1
var world_collision_check_phase: int = 0
var world_collision_step_index: int = 0
var world_collision_anchor := Vector2.ZERO
var world_collision_anchor_initialized := false
var last_world_collision_position := Vector2.ZERO
var world_collision_query := PhysicsRayQueryParameters2D.create(
	Vector2.ZERO,
	Vector2.ZERO,
	WORLD_COLLISION_MASK
)
var shadow_simulation_service: RapidFireSimulationService = null
var shadow_simulation_handle: int = RapidFireSimulationService.INVALID_HANDLE


func _ready() -> void:
	_authored_speed = speed
	_authored_max_lifetime = max_lifetime
	_authored_collision_layer = collision_layer
	_authored_collision_mask = collision_mask
	remaining_lifetime = maxf(max_lifetime, 0.01)
	pool_active = not has_meta(SessionObjectPool.POOL_OWNER_META)
	world_collision_query.collide_with_bodies = true
	world_collision_query.collide_with_areas = false
	body_entered.connect(_on_body_entered)
	if animated_sprite.sprite_frames != null and animated_sprite.sprite_frames.has_animation(&"fly"):
		animated_sprite.play(&"fly")


func _enter_tree() -> void:
	_try_attach_requested_batched_motion_system()


func on_pool_acquired(_generation: int) -> void:
	_release_shadow_simulation()
	remove_meta(&"damage_source_snapshot")
	combat_runtime = null
	gameplay_gateway = null
	_detach_batched_motion_system()
	_reset_world_collision_schedule()
	pool_active = true
	has_hit = false
	direction = Vector2.RIGHT
	damage = 1
	speed = _authored_speed
	max_lifetime = _authored_max_lifetime
	remaining_lifetime = maxf(max_lifetime, 0.01)
	projectile_id = 0
	owner_peer_id = 0
	source_type = &"capoo_ak47_bullet"
	damage_source_snapshot = null
	world_collision_pathfinder = null
	batched_activation_physics_frame = -1
	rotation = 0.0
	collision_layer = _authored_collision_layer
	collision_mask = _authored_collision_mask
	monitoring = true
	monitorable = true
	set_physics_process(true)
	if animated_sprite != null:
		animated_sprite.stop()
		animated_sprite.frame = 0
		animated_sprite.frame_progress = 0.0
		if animated_sprite.sprite_frames != null and animated_sprite.sprite_frames.has_animation(&"fly"):
			animated_sprite.play(&"fly")


func on_pool_released(_generation: int) -> void:
	_release_shadow_simulation()
	remove_meta(&"damage_source_snapshot")
	_detach_batched_motion_system()
	_reset_world_collision_schedule()
	pool_active = false
	has_hit = true
	world_collision_pathfinder = null
	combat_runtime = null
	gameplay_gateway = null
	damage_source_snapshot = null
	set_physics_process(false)
	set_deferred("monitoring", false)
	set_deferred("monitorable", false)
	if animated_sprite != null:
		animated_sprite.stop()


func bind_gameplay_context(
	runtime_context: CombatRuntimeBase,
	gateway: MultiplayerGameplayGateway
) -> void:
	combat_runtime = runtime_context
	gameplay_gateway = gateway


func bind_shadow_simulation(
	service: RapidFireSimulationService,
	handle: int
) -> bool:
	_release_shadow_simulation()
	if (
		service == null
		or not is_instance_valid(service)
		or handle <= RapidFireSimulationService.INVALID_HANDLE
		or not service.is_handle_live(handle)
		or service.get_slot_mode(handle)
			!= RapidFireSimulationService.Mode.SHADOW
	):
		return false
	shadow_simulation_service = service
	shadow_simulation_handle = handle
	return true


func setup(
	initial_direction: Vector2,
	initial_damage: int,
	initial_speed: float,
	initial_lifetime: float,
	shared_pathfinder: GridPathfinder = null,
	shared_motion_system: Node = null,
	initial_damage_source_snapshot: DamageSourceSnapshot = null
) -> void:
	_detach_batched_motion_system()
	_reset_world_collision_schedule()
	if initial_direction != Vector2.ZERO:
		direction = initial_direction.normalized()
		rotation = direction.angle()
	damage = maxi(initial_damage, 0)
	speed = maxf(initial_speed, 0.0)
	max_lifetime = maxf(initial_lifetime, 0.01)
	remaining_lifetime = max_lifetime
	damage_source_snapshot = (
		initial_damage_source_snapshot.duplicate_snapshot()
		if initial_damage_source_snapshot != null
		else null
	)
	if damage_source_snapshot != null:
		set_meta(
			&"damage_source_snapshot",
			damage_source_snapshot.duplicate_snapshot()
		)
	else:
		remove_meta(&"damage_source_snapshot")
	world_collision_pathfinder = shared_pathfinder
	if (
		CapooAK47Bullet.batched_motion_enabled
		and shared_motion_system != null
		and is_instance_valid(shared_motion_system)
	):
		requested_batched_motion_system = shared_motion_system
		set_physics_process(false)
		_try_attach_requested_batched_motion_system()
	else:
		set_physics_process(true)


func setup_multiplayer(
	new_projectile_id: int,
	new_owner_peer_id: int,
	new_source_type: StringName
) -> void:
	projectile_id = maxi(new_projectile_id, 0)
	owner_peer_id = new_owner_peer_id
	source_type = new_source_type
	_rebind_damage_source_snapshot_to_projectile_id()
	if projectile_id > 0:
		world_collision_check_phase = posmod(
			projectile_id,
			WORLD_COLLISION_CHECK_INTERVAL_FRAMES
		)


func _rebind_damage_source_snapshot_to_projectile_id() -> void:
	if damage_source_snapshot == null or projectile_id <= 0:
		return
	damage_source_snapshot = DamageSourceSnapshot.create(
		damage_source_snapshot.source_faction_id,
		damage_source_snapshot.credit_peer_id,
		damage_source_snapshot.instigator_entity_id,
		projectile_id,
		damage_source_snapshot.source_type
	)
	set_meta(
		&"damage_source_snapshot",
		damage_source_snapshot.duplicate_snapshot()
	)


func _physics_process(delta: float) -> void:
	if batched_motion_system != null:
		return
	_advance_projectile(delta)


func advance_batched(delta: float) -> void:
	if batched_motion_system == null:
		return
	_advance_projectile(delta)


func _advance_projectile(delta: float) -> void:
	if has_hit or not pool_active:
		return

	var current_position := global_position
	var next_position := current_position + direction * speed * delta
	if not world_collision_anchor_initialized:
		world_collision_anchor = current_position
		world_collision_anchor_initialized = true
	var remaining_after_step := remaining_lifetime - delta
	var current_check_phase := world_collision_step_index
	world_collision_step_index += 1
	if world_collision_step_index >= WORLD_COLLISION_CHECK_INTERVAL_FRAMES:
		world_collision_step_index = 0
	var should_check_world := current_check_phase == world_collision_check_phase
	# Never discard the final unchecked segment when lifetime ends on an
	# interleaved frame. Normal flight still performs one World ray per two
	# physics ticks, while position, lifetime and Area2D contacts remain 60 Hz.
	if should_check_world or remaining_after_step <= 0.0:
		if _will_hit_world(world_collision_anchor, next_position):
			global_position = last_world_collision_position
			world_collision_anchor = last_world_collision_position
			_record_shadow_observation()
			_consume(true)
			return
		world_collision_anchor = next_position

	global_position = next_position
	remaining_lifetime = remaining_after_step
	if remaining_lifetime <= 0.0:
		_record_shadow_observation()
		_consume(false)
		return
	_record_shadow_observation()


func _will_hit_world(from_position: Vector2, to_position: Vector2) -> bool:
	last_world_collision_position = to_position
	var started_usec := (
		Time.get_ticks_usec()
		if CapooAK47Bullet.performance_metrics_enabled
		else 0
	)
	if CapooAK47Bullet.performance_metrics_enabled:
		CapooAK47Bullet._performance_metrics["world_segment_calls"] = (
			int(CapooAK47Bullet._performance_metrics["world_segment_calls"]) + 1
		)
	if (
		CapooAK47Bullet.world_collision_certificate_enabled
		and world_collision_pathfinder != null
		and world_collision_pathfinder.is_world_collision_segment_certified_clear(
			from_position,
			to_position
		)
	):
		if CapooAK47Bullet.performance_metrics_enabled:
			CapooAK47Bullet._performance_metrics["certified_clear_calls"] = (
				int(CapooAK47Bullet._performance_metrics["certified_clear_calls"]) + 1
			)
			_record_world_segment_usec(started_usec)
		return false

	if CapooAK47Bullet.performance_metrics_enabled:
		CapooAK47Bullet._performance_metrics["physics_ray_calls"] = (
			int(CapooAK47Bullet._performance_metrics["physics_ray_calls"]) + 1
		)
	world_collision_query.from = from_position
	world_collision_query.to = to_position
	var hit_result := get_world_2d().direct_space_state.intersect_ray(
		world_collision_query
	)
	var did_hit := not hit_result.is_empty()
	if CapooAK47Bullet.performance_metrics_enabled:
		if did_hit:
			CapooAK47Bullet._performance_metrics["physics_ray_hits"] = (
				int(CapooAK47Bullet._performance_metrics["physics_ray_hits"]) + 1
			)
		_record_world_segment_usec(started_usec)
	if did_hit:
		last_world_collision_position = hit_result["position"] as Vector2
	return did_hit


static func reset_performance_metrics() -> void:
	for key in _performance_metrics:
		_performance_metrics[key] = 0


static func get_performance_metrics(reset_after_read: bool = false) -> Dictionary:
	var result := _performance_metrics.duplicate()
	if reset_after_read:
		reset_performance_metrics()
	return result


static func _record_world_segment_usec(started_usec: int) -> void:
	_performance_metrics["world_segment_usec"] = (
		int(_performance_metrics["world_segment_usec"])
		+ maxi(Time.get_ticks_usec() - started_usec, 0)
	)


func _on_body_entered(body: Node2D) -> void:
	if has_hit or not pool_active:
		return
	# Damageable bodies are still monitored at 60 Hz. If contact happens on the
	# interleaved frame, certify the unchecked suffix before applying damage so
	# a player or plant immediately behind a thin wall can never be hit through it.
	if _consume_if_unchecked_world_blocked():
		return

	var player := body as Player
	if player != null:
		if not _is_damage_admitted(player):
			return
		if (
			not _try_report_multiplayer_player_hit(player)
			and _has_explicit_singleplayer_authority()
		):
			var player_result := player.apply_combat_damage(
				_make_damage_request(direction, -direction)
			)
			if _should_ignore_non_hostile_result(player_result):
				return
		_consume(true)
		return

	var plant := body as PlantDefense
	if plant != null:
		if plant.is_dead or plant.is_removing:
			return
		if not _has_authoritative_runtime():
			_consume(true)
			return
		var plant_result := plant.apply_combat_damage(
			_make_damage_request(direction, -direction)
		)
		if _should_ignore_non_hostile_result(plant_result):
			return
		_consume(true)
		return

	var enemy := body as Enemy
	if enemy != null:
		if enemy.is_dead or not _has_authoritative_runtime():
			return
		var enemy_result := enemy.apply_combat_damage(
			_make_damage_request(direction, -direction)
		)
		if _should_ignore_non_hostile_result(enemy_result):
			return
		_consume(true)
		return

	_consume(true)


func _make_damage_request(
	impact_direction: Vector2,
	source_direction: Vector2
) -> DamageRequest:
	var request := DamageRequest.new(
		damage,
		EnemyConfig.DamageType.PHYSICAL
	)
	if damage_source_snapshot != null:
		request.with_source_snapshot(damage_source_snapshot)
	else:
		request.with_source(self, projectile_id, source_type)
	request.with_directions(impact_direction, source_direction)
	request.with_flag(CombatTypes.DamageFlag.RANGED, true)
	return request


func _should_ignore_non_hostile_result(result: DamageResult) -> bool:
	return (
		result != null
		and result.is_rejected_for(
			CombatTypes.DamageRejectionReason.NON_HOSTILE
		)
	)


func _reset_world_collision_schedule() -> void:
	world_collision_check_phase = posmod(
		int(get_instance_id()),
		WORLD_COLLISION_CHECK_INTERVAL_FRAMES
	)
	world_collision_step_index = 0
	world_collision_anchor = Vector2.ZERO
	world_collision_anchor_initialized = false
	last_world_collision_position = Vector2.ZERO


func _ensure_world_collision_anchor(current_position: Vector2) -> void:
	if world_collision_anchor_initialized:
		return
	world_collision_anchor = current_position
	world_collision_anchor_initialized = true


func _consume_if_unchecked_world_blocked() -> bool:
	_ensure_world_collision_anchor(global_position)
	if world_collision_anchor.is_equal_approx(global_position):
		return false
	if _will_hit_world(world_collision_anchor, global_position):
		global_position = last_world_collision_position
		world_collision_anchor = last_world_collision_position
		_consume(true)
		return true
	world_collision_anchor = global_position
	return false


func _consume(play_hit_effect: bool = true) -> void:
	if has_hit or not pool_active:
		return
	_detach_batched_motion_system()
	_release_shadow_simulation()
	has_hit = true
	pool_active = false
	set_physics_process(false)
	set_deferred("monitoring", false)
	set_deferred("monitorable", false)
	if play_hit_effect:
		_spawn_hit_effect()
	projectile_finished.emit(projectile_id, self)
	remove_meta(&"damage_source_snapshot")
	damage_source_snapshot = null
	if SessionObjectPool.release_to_owner(self):
		return
	queue_free()


func retire(play_hit_effect: bool = false) -> void:
	_consume(play_hit_effect)


func _exit_tree() -> void:
	_detach_batched_motion_system()
	_release_shadow_simulation()


func _record_shadow_observation() -> void:
	if (
		shadow_simulation_service == null
		or not is_instance_valid(shadow_simulation_service)
		or shadow_simulation_handle
			<= RapidFireSimulationService.INVALID_HANDLE
	):
		return
	shadow_simulation_service.record_shadow_observation(
		shadow_simulation_handle,
		global_position,
		maxf(remaining_lifetime, 0.0)
	)


func _release_shadow_simulation() -> void:
	var service := shadow_simulation_service
	var handle := shadow_simulation_handle
	shadow_simulation_service = null
	shadow_simulation_handle = RapidFireSimulationService.INVALID_HANDLE
	if (
		service != null
		and is_instance_valid(service)
		and handle > RapidFireSimulationService.INVALID_HANDLE
		and service.is_handle_live(handle)
	):
		service.release_projectile(handle)


func _detach_batched_motion_system() -> void:
	requested_batched_motion_system = null
	var system = batched_motion_system
	batched_motion_system = null
	batched_activation_physics_frame = -1
	if system != null and is_instance_valid(system):
		system.unregister_projectile(self)


func _try_attach_requested_batched_motion_system() -> void:
	if (
		batched_motion_system != null
		or requested_batched_motion_system == null
		or not is_inside_tree()
		or not is_instance_valid(requested_batched_motion_system)
	):
		return
	requested_batched_motion_system.call("register_projectile", self)


func _spawn_hit_effect() -> void:
	if combat_runtime == null or not is_instance_valid(combat_runtime):
		return
	var spawn_parent: Node = combat_runtime
	if not WORLD_EFFECT_VISIBILITY.is_position_near_viewport(
		self,
		global_position
	):
		return

	var effect: BulletHitEffect = null
	var uses_registered_pool := combat_runtime.has_session_object_pool_scene(
		HIT_EFFECT_SCENE
	)
	if uses_registered_pool:
		effect = combat_runtime.acquire_session_object(
			HIT_EFFECT_SCENE,
			true
		) as BulletHitEffect
	else:
		effect = HIT_EFFECT_SCENE.instantiate() as BulletHitEffect
	if effect == null:
		return

	effect.top_level = true
	if effect.get_parent() == null:
		spawn_parent.add_child(effect)
	elif effect.get_parent() != spawn_parent:
		effect.reparent(spawn_parent)
	effect.global_position = global_position
	effect.reset_physics_interpolation()
	effect.setup(direction)


func _try_report_multiplayer_player_hit(player: Player) -> bool:
	if (
		projectile_id <= 0
		or gameplay_gateway == null
		or not is_instance_valid(gameplay_gateway)
	):
		return false
	return gameplay_gateway.request_player_damage(
		projectile_id,
		player.peer_id,
		damage,
		source_type,
		EnemyConfig.DamageType.PHYSICAL,
		-direction,
		true,
		false,
		damage_source_snapshot
	)


func _is_damage_admitted(target: Node) -> bool:
	if not _has_authoritative_runtime():
		return true
	if target == null or not target.has_method(&"get_combat_faction_id"):
		return false
	return CombatDamageAdmission.is_admitted(
		_make_damage_request(direction, -direction),
		int(target.call(&"get_combat_faction_id")),
		combat_runtime.get_combat_relation_service()
	)


func _has_authoritative_runtime() -> bool:
	return (
		combat_runtime != null
		and is_instance_valid(combat_runtime)
		and combat_runtime.runtime_mode
			!= CombatRuntimeBase.RuntimeMode.CLIENT_VIEW
	)


func _has_explicit_singleplayer_authority() -> bool:
	return (
		_has_authoritative_runtime()
		and combat_runtime.runtime_mode
			== CombatRuntimeBase.RuntimeMode.SINGLEPLAYER
	)


func _get_player_damage_context() -> Dictionary:
	return {
		"is_ranged": true,
		"source_direction": -direction,
	}
