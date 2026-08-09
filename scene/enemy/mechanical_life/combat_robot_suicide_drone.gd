extends Node2D
class_name CombatRobotSuicideDrone

signal projectile_finished(projectile_id: int, projectile: Node)

const COMPLETE_SHAPE_QUERY_2D := preload("res://scene/combat/physics/complete_shape_query_2d.gd")
const ENEMY_ATTACK_AUDIO_LIMITER := preload("res://scene/combat/audio/enemy_attack_audio_limiter.gd")
const EXPLOSION_AUDIO_LIMITER := preload("res://scene/combat/audio/explosion_audio_limiter.gd")
const NIGHT_VFX_FLASH_POOL := preload("res://scene/lighting/night_vfx_flash_pool.gd")
const SPATIAL_AUDIO_VOICE_LIMITER := preload(
	"res://scene/combat/audio/spatial_audio_voice_limiter.gd"
)

const SOURCE_TYPE: StringName = &"combat_robot_suicide_drone"
const DAMAGEABLE_COLLISION_MASK := 2 | 512
const EXPLOSION_QUERY_BATCH_SIZE := 64
const DEPLOY_DELAY := 0.10
const DRONE_FRAME_COUNT := 4
const DRONE_FPS := 12.0
const MARKER_FRAME_COUNT := 4
const MARKER_FPS := 12.0
const EXPLOSION_FRAME_COUNT := 8
const EXPLOSION_FPS := 14.0
const EXPLOSION_DURATION := float(EXPLOSION_FRAME_COUNT) / EXPLOSION_FPS
const DEFAULT_SPEED := 60.0
const DEFAULT_MAX_LIFETIME := 80.0 / DEFAULT_SPEED
const DEFAULT_EXPLOSION_RADIUS := 28.0
const DEFAULT_DAMAGE := 50

@export var explosion_shape: Shape2D
@export var authored_source_type: StringName = SOURCE_TYPE
@export var explosion_flash_color := Color(1.0, 0.34, 0.12, 1.0)

@onready var drone_sprite: AnimatedSprite2D = $DroneSprite
@onready var target_marker: AnimatedSprite2D = $TargetMarker
@onready var explosion_sprite: AnimatedSprite2D = $ExplosionSprite
@onready var emission_overlay: AnimatedSprite2D = $ExplosionSprite/EmissionOverlay
@onready var launch_audio: AudioStreamPlayer2D = $LaunchAudio
@onready var explosion_audio: AudioStreamPlayer2D = $ExplosionAudio

var direction := Vector2.RIGHT
var damage: int = DEFAULT_DAMAGE
var speed: float = DEFAULT_SPEED
var max_lifetime: float = DEFAULT_MAX_LIFETIME
var remaining_lifetime: float = DEFAULT_MAX_LIFETIME
var explosion_radius: float = DEFAULT_EXPLOSION_RADIUS
var projectile_id: int = 0
var owner_peer_id: int = 0
var source_type: StringName = SOURCE_TYPE
var pool_active := true
var authoritative_damage := true
var combat_runtime: CombatRuntimeBase = null
var gameplay_gateway: MultiplayerGameplayGateway = null

var deployment_started := false
var flight_started := false
var explosion_started := false
var contract_elapsed := 0.0
var start_position := Vector2.ZERO
var target_position := Vector2.ZERO
var target_offset := Vector2.ZERO

var batched_motion_system: Node = null
var batched_activation_physics_frame := -1
var explosion_query := PhysicsShapeQueryParameters2D.new()
var explosion_damaged_bodies: Dictionary[int, bool] = {}
var _explosion_completion_pending := false
var _explosion_visual_done := true
var _explosion_audio_done := true


func _ready() -> void:
	pool_active = not has_meta(SessionObjectPool.POOL_OWNER_META)
	source_type = authored_source_type
	explosion_query.collide_with_bodies = true
	explosion_query.collide_with_areas = false
	explosion_audio.set_meta(
		SPATIAL_AUDIO_VOICE_LIMITER.VOICE_PREEMPTED_CALLBACK_META,
		_on_explosion_audio_preempted
	)
	_apply_explosion_radius()
	_reset_visuals()
	set_process(false)
	set_physics_process(false)


func on_pool_acquired(_generation: int) -> void:
	# A pooled projectile must never retain the previous session/runtime lease.
	# Its creator binds the new context immediately after acquisition.
	combat_runtime = null
	gameplay_gateway = null
	pool_active = true
	direction = Vector2.RIGHT
	damage = DEFAULT_DAMAGE
	speed = DEFAULT_SPEED
	max_lifetime = DEFAULT_MAX_LIFETIME
	remaining_lifetime = DEFAULT_MAX_LIFETIME
	explosion_radius = DEFAULT_EXPLOSION_RADIUS
	projectile_id = 0
	owner_peer_id = 0
	source_type = authored_source_type
	authoritative_damage = true
	deployment_started = false
	flight_started = false
	explosion_started = false
	contract_elapsed = 0.0
	start_position = Vector2.ZERO
	target_position = Vector2.ZERO
	target_offset = Vector2.ZERO
	batched_activation_physics_frame = -1
	explosion_damaged_bodies.clear()
	_explosion_completion_pending = false
	_explosion_visual_done = true
	_explosion_audio_done = true
	modulate = Color.WHITE
	self_modulate = Color.WHITE
	rotation = 0.0
	_apply_explosion_radius()
	_stop_audio()
	_reset_visuals()
	set_process(false)
	set_physics_process(false)


func on_pool_released(_generation: int) -> void:
	pool_active = false
	deployment_started = false
	flight_started = false
	explosion_started = false
	contract_elapsed = 0.0
	remaining_lifetime = 0.0
	explosion_damaged_bodies.clear()
	_explosion_completion_pending = false
	_explosion_visual_done = true
	_explosion_audio_done = true
	combat_runtime = null
	gameplay_gateway = null
	source_type = authored_source_type
	_unregister_from_motion_system()
	_stop_audio()
	_reset_visuals()
	set_process(false)
	set_physics_process(false)


func bind_gameplay_context(
	runtime_context: CombatRuntimeBase,
	gateway: MultiplayerGameplayGateway
) -> void:
	combat_runtime = runtime_context
	gameplay_gateway = gateway


func setup(
	initial_direction: Vector2,
	initial_damage: int,
	initial_speed: float,
	initial_flight_duration: float,
	initial_explosion_radius: float,
	motion_system: Node
) -> void:
	pool_active = true
	direction = (
		initial_direction.normalized()
		if initial_direction != Vector2.ZERO
		else Vector2.RIGHT
	)
	damage = maxi(initial_damage, 0)
	speed = maxf(initial_speed, 0.0)
	max_lifetime = maxf(initial_flight_duration, 0.0)
	remaining_lifetime = max_lifetime
	explosion_radius = maxf(initial_explosion_radius, 0.0)
	batched_motion_system = motion_system
	authoritative_damage = true
	_apply_explosion_radius()


func setup_multiplayer(
	new_projectile_id: int,
	new_owner_peer_id: int,
	new_source_type: StringName
) -> void:
	projectile_id = maxi(new_projectile_id, 0)
	owner_peer_id = new_owner_peer_id
	source_type = (
		new_source_type
		if new_source_type != &""
		else authored_source_type
	)


func begin_deployment() -> bool:
	if not pool_active or deployment_started:
		return deployment_started
	if batched_motion_system == null or not is_instance_valid(batched_motion_system):
		return false
	deployment_started = true
	flight_started = false
	explosion_started = false
	contract_elapsed = 0.0
	remaining_lifetime = max_lifetime
	start_position = global_position
	target_offset = direction * speed * max_lifetime
	target_position = start_position + target_offset
	explosion_damaged_bodies.clear()
	batched_motion_system.call("register_drone", self)
	_render_contract_elapsed(0.0, false, false)
	return true


func advance_batched(delta: float) -> void:
	if not pool_active or not deployment_started:
		return
	contract_elapsed = maxf(contract_elapsed + maxf(delta, 0.0), 0.0)
	_render_contract_elapsed(contract_elapsed, true, false)


func simulate_compensated_motion(compensation_age: float) -> void:
	if not pool_active:
		return
	if not deployment_started and not begin_deployment():
		return
	contract_elapsed = maxf(compensation_age, 0.0)
	_render_contract_elapsed(contract_elapsed, false, true)


func get_total_contract_duration() -> float:
	return DEPLOY_DELAY + max_lifetime + EXPLOSION_DURATION


func retire() -> void:
	_retire()


func _render_contract_elapsed(
	elapsed: float,
	allow_transition_audio: bool,
	compensated: bool
) -> void:
	if not pool_active:
		return
	var safe_elapsed := maxf(elapsed, 0.0)
	var flight_end := DEPLOY_DELAY + max_lifetime
	var contract_end := flight_end + EXPLOSION_DURATION
	_update_marker_frame(safe_elapsed)

	if safe_elapsed < DEPLOY_DELAY:
		remaining_lifetime = max_lifetime
		target_marker.show()
		drone_sprite.hide()
		explosion_sprite.hide()
		return

	if safe_elapsed < flight_end:
		if not flight_started:
			flight_started = true
			if allow_transition_audio:
				ENEMY_ATTACK_AUDIO_LIMITER.play_heavy_attack(launch_audio)
		var flight_elapsed := safe_elapsed - DEPLOY_DELAY
		var progress := (
			clampf(flight_elapsed / max_lifetime, 0.0, 1.0)
			if max_lifetime > 0.0
			else 1.0
		)
		remaining_lifetime = maxf(max_lifetime - flight_elapsed, 0.0)
		target_marker.show()
		drone_sprite.show()
		explosion_sprite.hide()
		drone_sprite.position = target_offset * progress
		drone_sprite.rotation = direction.angle()
		drone_sprite.frame = posmod(
			floori(flight_elapsed * DRONE_FPS),
			DRONE_FRAME_COUNT
		)
		return

	remaining_lifetime = 0.0
	var explosion_elapsed := maxf(safe_elapsed - flight_end, 0.0)
	if not explosion_started:
		_enter_explosion(explosion_elapsed, allow_transition_audio, compensated)
	if safe_elapsed >= contract_end:
		_complete_explosion_visual()
		return
	var explosion_frame := clampi(
		floori(explosion_elapsed * EXPLOSION_FPS),
		0,
		EXPLOSION_FRAME_COUNT - 1
	)
	explosion_sprite.frame = explosion_frame
	emission_overlay.frame = explosion_frame


func _enter_explosion(
	explosion_elapsed: float,
	allow_transition_audio: bool,
	compensated: bool
) -> void:
	explosion_started = true
	flight_started = true
	_explosion_completion_pending = true
	_explosion_visual_done = explosion_elapsed >= EXPLOSION_DURATION
	_explosion_audio_done = true
	target_marker.hide()
	drone_sprite.hide()
	explosion_sprite.position = target_offset
	explosion_audio.position = target_offset
	explosion_sprite.show()
	explosion_sprite.frame = 0
	emission_overlay.show()
	emission_overlay.frame = 0
	if authoritative_damage and not _is_client_view_runtime():
		_apply_explosion_damage()
	var should_play_audio := (
		allow_transition_audio
		or (compensated and explosion_elapsed <= 0.16)
	)
	if should_play_audio:
		EXPLOSION_AUDIO_LIMITER.play(explosion_audio)
		_explosion_audio_done = not explosion_audio.playing
	NIGHT_VFX_FLASH_POOL.request_from(
		self,
		target_position,
		explosion_flash_color,
		1.0,
		0.62,
		0.035,
		0.05,
		0.24,
		2,
		explosion_elapsed
	)


func _complete_explosion_visual() -> void:
	if not _explosion_completion_pending:
		return
	_explosion_visual_done = true
	if explosion_sprite != null:
		explosion_sprite.hide()
	if emission_overlay != null:
		emission_overlay.hide()
	_unregister_from_motion_system()
	_try_finish_explosion()


func _on_explosion_audio_finished() -> void:
	if not _explosion_completion_pending:
		return
	_explosion_audio_done = true
	_try_finish_explosion()


func _on_explosion_audio_preempted() -> void:
	if not _explosion_completion_pending:
		return
	_explosion_audio_done = true
	_try_finish_explosion()


func _try_finish_explosion() -> void:
	if (
		not _explosion_completion_pending
		or not _explosion_visual_done
		or not _explosion_audio_done
	):
		return
	_explosion_completion_pending = false
	_retire()


func _apply_explosion_damage() -> void:
	if explosion_shape == null or damage <= 0:
		return
	explosion_query.shape = explosion_shape
	explosion_query.transform = Transform2D(0.0, target_position)
	explosion_query.collision_mask = DAMAGEABLE_COLLISION_MASK
	explosion_query.exclude = []
	explosion_damaged_bodies.clear()
	var results := COMPLETE_SHAPE_QUERY_2D.intersect_shape_all(
		get_world_2d().direct_space_state,
		explosion_query,
		EXPLOSION_QUERY_BATCH_SIZE
	)
	for result in results:
		_apply_explosion_damage_to_body(result.get("collider") as Node2D)


func _apply_explosion_damage_to_body(body: Node2D) -> void:
	if body == null or not is_instance_valid(body):
		return
	var body_id := body.get_instance_id()
	if explosion_damaged_bodies.has(body_id):
		return
	var player := body as Player
	if player != null:
		if player.is_dead:
			return
		explosion_damaged_bodies[body_id] = true
		var source_direction := player.global_position.direction_to(target_position)
		if not _try_report_multiplayer_player_hit(player, source_direction):
			player.apply_damage(
				damage,
				EnemyConfig.DamageType.PHYSICAL,
				{
					"is_ranged": true,
					"source_direction": source_direction,
				}
			)
		return
	var plant := body as PlantDefense
	if plant == null or plant.is_dead or plant.is_removing:
		return
	explosion_damaged_bodies[body_id] = true
	plant.receive_damage(
		damage,
		self,
		target_position.direction_to(plant.global_position),
		EnemyConfig.DamageType.PHYSICAL
	)


func _try_report_multiplayer_player_hit(
	player: Player,
	source_direction: Vector2
) -> bool:
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
		source_direction,
		true
	)


func _is_client_view_runtime() -> bool:
	if combat_runtime != null and is_instance_valid(combat_runtime):
		return (
			combat_runtime.runtime_mode
			== CombatRuntimeBase.RuntimeMode.CLIENT_VIEW
		)
	if gameplay_gateway != null and is_instance_valid(gameplay_gateway):
		return gameplay_gateway.is_client_view()
	# A replicated projectile without an injected authority context must fail
	# closed. Host projectiles receive their runtime before network registration.
	return projectile_id > 0


func _update_marker_frame(elapsed: float) -> void:
	target_marker.position = target_offset
	target_marker.rotation = 0.0
	target_marker.frame = posmod(
		floori(elapsed * MARKER_FPS),
		MARKER_FRAME_COUNT
	)


func _apply_explosion_radius() -> void:
	var circle := explosion_shape as CircleShape2D
	if circle != null:
		circle.radius = maxf(explosion_radius, 0.0)


func _reset_visuals() -> void:
	if drone_sprite != null:
		drone_sprite.hide()
		drone_sprite.position = Vector2.ZERO
		drone_sprite.rotation = 0.0
		drone_sprite.frame = 0
		drone_sprite.frame_progress = 0.0
	if target_marker != null:
		target_marker.hide()
		target_marker.position = Vector2.ZERO
		target_marker.rotation = 0.0
		target_marker.frame = 0
		target_marker.frame_progress = 0.0
	if explosion_sprite != null:
		explosion_sprite.hide()
		explosion_sprite.position = Vector2.ZERO
		explosion_sprite.rotation = 0.0
		explosion_sprite.frame = 0
		explosion_sprite.frame_progress = 0.0
	if emission_overlay != null:
		emission_overlay.frame = 0
		emission_overlay.frame_progress = 0.0
	if launch_audio != null:
		launch_audio.position = Vector2.ZERO
	if explosion_audio != null:
		explosion_audio.position = Vector2.ZERO


func _stop_audio() -> void:
	if launch_audio != null:
		launch_audio.stop()
		if launch_audio.is_in_group(
			ENEMY_ATTACK_AUDIO_LIMITER.HEAVY_ATTACK_AUDIO_GROUP
		):
			launch_audio.remove_from_group(
				ENEMY_ATTACK_AUDIO_LIMITER.HEAVY_ATTACK_AUDIO_GROUP
			)
	EXPLOSION_AUDIO_LIMITER.stop(explosion_audio)


func _unregister_from_motion_system() -> void:
	var motion_system := batched_motion_system
	batched_motion_system = null
	if motion_system != null and is_instance_valid(motion_system):
		motion_system.call("unregister_drone", self)


func _retire() -> void:
	if not pool_active:
		return
	pool_active = false
	deployment_started = false
	_unregister_from_motion_system()
	projectile_finished.emit(projectile_id, self)
	if SessionObjectPool.release_to_owner(self):
		return
	queue_free()
