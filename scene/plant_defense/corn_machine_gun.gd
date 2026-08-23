extends PlantDefense
class_name CornMachineGun

signal burst_shot_emitted(shot_index: int, authoritative: bool)

const AUDIO_LIMITER := preload("res://scene/combat/audio/plant_attack_audio_limiter.gd")
const ATTACK_PHASE_SCHEDULER := preload(
	"res://scene/plant_defense/plant_attack_phase_scheduler.gd"
)
const PROJECTILE_SHIELD_COLLISION_MASK := 1 << 12
const WORLD_AND_ENEMY_COLLISION_MASK := 5 | PROJECTILE_SHIELD_COLLISION_MASK
const DEFAULT_ATTACK_DAMAGE := 30
const DEFAULT_ATTACK_RANGE := 160.0
const DEFAULT_ATTACK_INTERVAL := 0.9
const DEFAULT_BURST_COUNT := 6
const DEFAULT_BURST_SHOT_INTERVAL := 0.06
const IDLE_AIM_LIMIT := 0.26179939 # 15 degrees; 30 degrees across the full arc.
const IDLE_AIM_MIN_TARGET_OFFSET := 0.05235988 # 3 degrees from the center.
const IDLE_AIM_INTERVAL_MIN := 0.75
const IDLE_AIM_INTERVAL_MAX := 1.15
const AIM_RETURN_DELAY_SECONDS := 1.0
const AIM_RETURN_DURATION_SECONDS := 0.25
const TRACER_MAX_LENGTH := 20.0
const BURST_TIME_EPSILON := 0.00001
const PROXY_BURST_EXPIRY_MARGIN_SECONDS := 0.02
# Public compatibility value for the authored six-shot burst. Runtime expiry is
# derived from each action's frozen shot count by _get_burst_expiry_seconds().
const PROXY_BURST_EXPIRY_SECONDS := (
	float(DEFAULT_BURST_COUNT - 1) * DEFAULT_BURST_SHOT_INTERVAL
	+ PROXY_BURST_EXPIRY_MARGIN_SECONDS
)
const LINEAR_BLOCKED_TARGET_ATTEMPTS := 3
const INITIAL_ATTACK_DELAY_MIN_SECONDS := 0.05

@onready var body_sprite: AnimatedSprite2D = $VisualRoot/BodySprite
@onready var aim_pivot: Node2D = $VisualRoot/AimPivot
@onready var turret_sprite: AnimatedSprite2D = $VisualRoot/AimPivot/TurretSprite
@onready var forward_marker: Marker2D = $VisualRoot/AimPivot/ForwardMarker
@onready var muzzle: Marker2D = $VisualRoot/AimPivot/Muzzle
@onready var muzzle_flash_sprite: AnimatedSprite2D = (
	$VisualRoot/AimPivot/MuzzleFlashSprite
)
@onready var muzzle_emission_overlay: AnimatedSprite2D = (
	$VisualRoot/AimPivot/MuzzleFlashSprite/EmissionOverlay
)
@onready var tracer: Line2D = $Tracer
@onready var tracer_halo: Line2D = $Tracer/ProjectileHalo
@onready var tracer_fade: AnimationPlayer = $TracerFade
@onready var attack_timer: Timer = $AttackTimer
@onready var idle_aim_timer: Timer = $IdleAimTimer
@onready var aim_return_timer: Timer = $AimReturnTimer
@onready var health_bar: Control = $HealthBar
@onready var fire_audio: AudioStreamPlayer2D = $FireAudio

var configured_attack_damage := DEFAULT_ATTACK_DAMAGE
var configured_attack_range := DEFAULT_ATTACK_RANGE
var configured_burst_count := DEFAULT_BURST_COUNT
var configured_burst_shot_interval := DEFAULT_BURST_SHOT_INTERVAL
var research_burst_shot_count_bonus := 0

var burst_active := false
var burst_authoritative := false
var burst_direction := Vector2.RIGHT
var burst_elapsed_seconds := 0.0
var burst_next_shot_index := 0
var active_burst_shot_count := DEFAULT_BURST_COUNT
var burst_action_id := 0
var burst_muzzle_position := Vector2.ZERO
var next_authoritative_action_id := 0
var latest_proxy_action_id := 0
var _hitscan_query_count := 0
var _target_candidates: Array[Enemy] = []
var _ray_exclude: Array[RID] = []
var _shield_retry_exclude: Array[RID] = []
var _ray_query := PhysicsRayQueryParameters2D.create(
	Vector2.ZERO,
	Vector2.ZERO,
	WORLD_AND_ENEMY_COLLISION_MASK
)

var idle_aim_random := RandomNumberGenerator.new()
# Authored local rotation captured once during setup. Combat aim must never
# redefine this center; every return to idle starts from the scene default.
var idle_aim_center_rotation := 0.0
var idle_aim_last_direction := 0
var idle_aim_active := false
var _aim_return_tween: Tween = null


func _ready() -> void:
	super._ready()
	set_physics_process(false)
	tracer.visible = false
	muzzle_flash_sprite.visible = false
	muzzle_emission_overlay.visible = false


func _physics_process(delta: float) -> void:
	if not burst_active:
		set_physics_process(false)
		return
	burst_elapsed_seconds += maxf(delta, 0.0)
	_emit_due_burst_shots()


func _on_setup_completed() -> void:
	super._on_setup_completed()
	_ray_exclude.clear()
	_ray_exclude.append(get_rid())
	_configure_ray_query()
	_set_ray_query_segment(Vector2.ZERO, Vector2.ZERO)
	configured_attack_damage = maxi(config.attack_damage, 0)
	configured_attack_range = maxf(config.attack_range, 0.0)
	_refresh_configured_burst_count()
	configured_burst_shot_interval = maxf(config.attack_burst_shot_interval, 0.0)

	health_bar.call("setup", max_health, current_health)
	if not health_changed.is_connected(_on_health_changed):
		health_changed.connect(_on_health_changed)
	if not attack_interval_multiplier_changed.is_connected(
		_on_attack_interval_multiplier_changed
	):
		attack_interval_multiplier_changed.connect(
			_on_attack_interval_multiplier_changed
		)

	body_sprite.play(&"idle")
	turret_sprite.play(&"idle")
	idle_aim_center_rotation = aim_pivot.rotation
	idle_aim_random.randomize()


func _on_operational_started() -> void:
	_start_idle_aim()
	if is_multiplayer_proxy:
		_disable_proxy_combat_runtime()
		return

	var attack_interval := _get_effective_attack_interval()
	var initial_attack_delay := calculate_initial_attack_delay_seconds(
		attack_interval,
		_get_attack_phase_identity()
	)
	# Towers restored or created in one frame must not keep the same 0.9 s
	# phase forever. The deterministic first delay spreads target locks across
	# the authored cycle; restoring wait_time preserves the exact repeat rate.
	attack_timer.start(initial_attack_delay)
	attack_timer.wait_time = attack_interval


static func calculate_initial_attack_delay_seconds(
	attack_interval: float,
	phase_identity: int
) -> float:
	return ATTACK_PHASE_SCHEDULER.calculate_initial_delay_seconds(
		attack_interval,
		phase_identity,
		INITIAL_ATTACK_DELAY_MIN_SECONDS
	)


func get_initial_attack_delay_seconds() -> float:
	var attack_interval := _get_effective_attack_interval()
	return calculate_initial_attack_delay_seconds(
		attack_interval,
		_get_attack_phase_identity()
	)


func _get_attack_phase_identity() -> int:
	return ATTACK_PHASE_SCHEDULER.resolve_plant_identity(self)


func _on_multiplayer_proxy_configured() -> void:
	_disable_proxy_combat_runtime()


func _disable_proxy_combat_runtime() -> void:
	attack_timer.stop()
	_cancel_burst(false)
	_target_candidates.clear()


func _on_removal_started(_mode: RemovalMode) -> void:
	attack_timer.stop()
	_stop_idle_aim()
	_cancel_aim_return()
	health_bar.hide()
	_cancel_burst(false)
	tracer_fade.stop()
	tracer.visible = false
	muzzle_flash_sprite.visible = false
	muzzle_emission_overlay.stop()
	muzzle_emission_overlay.visible = false
	fire_audio.stop()
	_target_candidates.clear()


func _on_health_changed(new_health: int, new_max_health: int) -> void:
	health_bar.call("set_health", new_health, new_max_health)


func set_research_burst_shot_count_bonus(bonus: int) -> void:
	research_burst_shot_count_bonus = maxi(bonus, 0)
	_refresh_configured_burst_count()


func get_research_burst_shot_count_bonus() -> int:
	return research_burst_shot_count_bonus


func _refresh_configured_burst_count() -> void:
	var base_burst_count := (
		config.attack_burst_count if config != null else DEFAULT_BURST_COUNT
	)
	configured_burst_count = maxi(base_burst_count, 1) + research_burst_shot_count_bonus


func _get_authored_attack_interval() -> float:
	var authored_interval := config.get_attack_interval() if config != null else 0.0
	return authored_interval if authored_interval > 0.0 else DEFAULT_ATTACK_INTERVAL


func _get_effective_attack_interval() -> float:
	return get_effective_attack_interval(_get_authored_attack_interval())


func _on_attack_interval_multiplier_changed(
	previous_multiplier: float,
	current_multiplier: float
) -> void:
	if is_multiplayer_proxy or not is_operational or is_dead or is_removing:
		return
	var authored_interval := _get_authored_attack_interval()
	PlantDefense.retime_attack_cycle_timer(
		attack_timer,
		authored_interval * previous_multiplier,
		authored_interval * current_multiplier
	)


func _on_attack_timer_timeout() -> void:
	if is_multiplayer_proxy or is_dead or burst_active:
		return
	var target := _select_nearest_visible_enemy()
	if target == null:
		if (
			not idle_aim_active
			and aim_return_timer.is_stopped()
			and _aim_return_tween == null
		):
			_schedule_aim_return()
		return
	var locked_direction := aim_pivot.global_position.direction_to(target.global_position)
	if locked_direction == Vector2.ZERO:
		return
	_start_authoritative_burst(locked_direction.normalized())


func _start_authoritative_burst(direction: Vector2) -> void:
	if is_multiplayer_proxy or is_dead or direction == Vector2.ZERO:
		return
	next_authoritative_action_id += 1
	var action_id := next_authoritative_action_id
	var safe_direction := direction.normalized()
	# Research can complete while an already-started burst is still firing. Freeze
	# the authored shot count once per action so that one burst cannot grow midway.
	var shot_count := configured_burst_count
	if (
		tower_multiplayer_mode_adapter != null
		and is_instance_valid(tower_multiplayer_mode_adapter)
	):
		tower_multiplayer_mode_adapter.queue_corn_machine_gun_burst_visual(
			int(get_meta(&"net_id", 0)),
			action_id,
			safe_direction,
			shot_count
		)
	_begin_burst(safe_direction, action_id, 0.0, true, shot_count)


func play_multiplayer_burst(
	direction: Vector2,
	action_id: int,
	elapsed_seconds: float,
	shot_count: int
) -> void:
	if (
		not is_multiplayer_proxy
		or is_dead
		or action_id <= latest_proxy_action_id
		or direction == Vector2.ZERO
		or shot_count <= 0
	):
		return
	latest_proxy_action_id = action_id
	var safe_elapsed := maxf(elapsed_seconds, 0.0)
	if safe_elapsed >= _get_burst_expiry_seconds(shot_count):
		if burst_active:
			_cancel_burst(true)
		return
	_begin_burst(
		direction.normalized(),
		action_id,
		safe_elapsed,
		false,
		shot_count
	)


func _begin_burst(
	direction: Vector2,
	action_id: int,
	elapsed_seconds: float,
	authoritative: bool,
	shot_count: int
) -> void:
	_cancel_aim_return()
	_stop_idle_aim()
	_cancel_burst(false)
	burst_active = true
	burst_authoritative = authoritative
	burst_direction = direction.normalized() if direction != Vector2.ZERO else Vector2.RIGHT
	burst_elapsed_seconds = maxf(elapsed_seconds, 0.0)
	burst_action_id = action_id
	active_burst_shot_count = shot_count
	burst_next_shot_index = (
		0 if authoritative else _get_first_future_proxy_shot_index(burst_elapsed_seconds)
	)
	_point_aim_at_direction(burst_direction)
	# A Corn tower and its AimPivot remain fixed throughout the locked 0.30 s
	# burst. Snapshot the one authored muzzle transform once instead of asking the
	# scene tree to resolve the same global transform and angle for all six shots.
	burst_muzzle_position = muzzle.global_position
	tracer.global_position = burst_muzzle_position
	tracer.global_rotation = burst_direction.angle()
	turret_sprite.play(&"spin")
	if turret_sprite.sprite_frames != null and turret_sprite.sprite_frames.has_animation(&"spin"):
		var spin_frame_count := turret_sprite.sprite_frames.get_frame_count(&"spin")
		if spin_frame_count > 0:
			var spin_frame_position := burst_elapsed_seconds * 20.0
			var spin_frame := floori(spin_frame_position) % spin_frame_count
			var spin_progress := fposmod(spin_frame_position, 1.0)
			turret_sprite.set_frame_and_progress(spin_frame, spin_progress)
	AUDIO_LIMITER.play_burst(fire_audio, burst_elapsed_seconds)
	set_physics_process(true)
	_emit_due_burst_shots()


func _get_first_future_proxy_shot_index(elapsed_seconds: float) -> int:
	if elapsed_seconds <= BURST_TIME_EPSILON:
		return 0
	if configured_burst_shot_interval <= 0.0:
		return active_burst_shot_count
	return clampi(
		floori(elapsed_seconds / configured_burst_shot_interval) + 1,
		0,
		active_burst_shot_count
	)


func _emit_due_burst_shots() -> void:
	while burst_active and burst_next_shot_index < active_burst_shot_count:
		var scheduled_time := (
			float(burst_next_shot_index) * configured_burst_shot_interval
		)
		if burst_elapsed_seconds + BURST_TIME_EPSILON < scheduled_time:
			break
		var shot_index := burst_next_shot_index
		burst_next_shot_index += 1
		_fire_locked_hitscan(shot_index, burst_authoritative)

	if burst_active and burst_next_shot_index >= active_burst_shot_count:
		_finish_burst()


func _get_burst_expiry_seconds(shot_count: int) -> float:
	return (
		float(maxi(shot_count - 1, 0)) * configured_burst_shot_interval
		+ PROXY_BURST_EXPIRY_MARGIN_SECONDS
	)


func _fire_locked_hitscan(shot_index: int, authoritative: bool) -> void:
	var tracer_length := minf(configured_attack_range, TRACER_MAX_LENGTH)
	if not authoritative:
		_play_locked_shot_visual(tracer_length)
		burst_shot_emitted.emit(shot_index, false)
		return

	var ray_result := _cast_locked_hitscan_from(
		burst_muzzle_position,
		burst_direction
	)
	var shield := _get_projectile_shield(ray_result)
	if shield != null:
		if shield.try_intercept(burst_direction):
			tracer_length = _get_hit_tracer_length(ray_result, tracer_length)
			_play_locked_shot_visual(maxf(tracer_length, 0.0))
			burst_shot_emitted.emit(shot_index, true)
			return
		# A broken or back-facing shield is transparent. The twentieth shot disables
		# the layer synchronously, but a query already in flight can still carry its
		# old RID; exclude only that area and repeat at most once for this edge case.
		ray_result = _cast_locked_hitscan_from_excluding_shield(
			burst_muzzle_position,
			burst_direction,
			shield
		)
		var retry_shield := _get_projectile_shield(ray_result)
		if retry_shield != null:
			if retry_shield.try_intercept(burst_direction):
				tracer_length = _get_hit_tracer_length(ray_result, tracer_length)
				_play_locked_shot_visual(maxf(tracer_length, 0.0))
				burst_shot_emitted.emit(shot_index, true)
				return
			# The single stale-RID retry budget is exhausted. A second transparent
			# shield must not be miscast as an Enemy or receive direct damage.
			ray_result.clear()
	if not ray_result.is_empty():
		tracer_length = _get_hit_tracer_length(ray_result, tracer_length)
	_play_locked_shot_visual(maxf(tracer_length, 0.0))
	burst_shot_emitted.emit(shot_index, true)

	if ray_result.is_empty():
		return
	var enemy := ray_result.get("collider") as Enemy
	if not _is_valid_target(enemy):
		return
	if (
		combat_runtime != null
		and is_instance_valid(combat_runtime)
		and tower_multiplayer_mode_adapter != null
		and is_instance_valid(tower_multiplayer_mode_adapter)
	):
		tower_multiplayer_mode_adapter.apply_authoritative_plant_enemy_damage(
			int(get_meta(&"net_id", get_instance_id())),
			enemy,
			configured_attack_damage,
			burst_direction,
			EnemyConfig.DamageType.PHYSICAL
		)


func _cast_locked_hitscan(direction: Vector2) -> Dictionary:
	var safe_direction := direction.normalized() if direction != Vector2.ZERO else Vector2.RIGHT
	return _cast_locked_hitscan_from(muzzle.global_position, safe_direction)


func _cast_locked_hitscan_from(
	ray_start: Vector2,
	normalized_direction: Vector2
) -> Dictionary:
	_hitscan_query_count += 1
	_set_ray_query_segment(
		ray_start,
		ray_start + normalized_direction * configured_attack_range
	)
	return get_world_2d().direct_space_state.intersect_ray(_ray_query)


func _cast_locked_hitscan_from_excluding_shield(
	ray_start: Vector2,
	normalized_direction: Vector2,
	shield: ProjectileShieldArea
) -> Dictionary:
	if shield == null or not is_instance_valid(shield):
		return {}
	_hitscan_query_count += 1
	_set_ray_query_segment(
		ray_start,
		ray_start + normalized_direction * configured_attack_range
	)
	_shield_retry_exclude.clear()
	_shield_retry_exclude.append(get_rid())
	_shield_retry_exclude.append(shield.get_rid())
	_ray_query.exclude = _shield_retry_exclude
	var result := get_world_2d().direct_space_state.intersect_ray(_ray_query)
	_ray_query.exclude = _ray_exclude
	_shield_retry_exclude.clear()
	return result


func _get_projectile_shield(ray_result: Dictionary) -> ProjectileShieldArea:
	if ray_result.is_empty():
		return null
	return ray_result.get("collider") as ProjectileShieldArea


func _get_hit_tracer_length(ray_result: Dictionary, fallback_length: float) -> float:
	var hit_position: Vector2 = ray_result.get(
		"position",
		burst_muzzle_position + burst_direction * fallback_length
	)
	return minf(fallback_length, burst_muzzle_position.distance_to(hit_position))


func _configure_ray_query() -> void:
	# All invariant fields are private to this tower and remain unchanged across
	# acquisition and the six synchronous hitscans. Configure them once so the
	# RID exclusion Array is not copied back into the native query every shot.
	_ray_query.collision_mask = WORLD_AND_ENEMY_COLLISION_MASK
	_ray_query.exclude = _ray_exclude
	_ray_query.collide_with_bodies = true
	_ray_query.collide_with_areas = true
	_ray_query.hit_from_inside = false


func _set_ray_query_segment(ray_from: Vector2, ray_to: Vector2) -> void:
	_ray_query.from = ray_from
	_ray_query.to = ray_to


func get_hitscan_query_count() -> int:
	return _hitscan_query_count


func _play_shot_visual(direction: Vector2, tracer_length: float) -> void:
	tracer.global_position = muzzle.global_position
	tracer.global_rotation = direction.angle()
	_restart_shot_visual(tracer_length)


func _play_locked_shot_visual(tracer_length: float) -> void:
	_restart_shot_visual(tracer_length)


func _restart_shot_visual(tracer_length: float) -> void:
	muzzle_flash_sprite.stop()
	muzzle_flash_sprite.frame = 0
	muzzle_flash_sprite.visible = true
	muzzle_flash_sprite.play(&"flash")
	muzzle_emission_overlay.stop()
	muzzle_emission_overlay.frame = 0
	muzzle_emission_overlay.visible = true
	muzzle_emission_overlay.play(&"flash")

	tracer.set_point_position(1, Vector2(tracer_length, 0.0))
	tracer_halo.set_point_position(1, Vector2(tracer_length, 0.0))
	tracer.visible = tracer_length > 0.0
	tracer.modulate.a = 1.0
	tracer_fade.stop()
	tracer_fade.play(&"fade")


func _finish_burst() -> void:
	if not burst_active:
		return
	burst_active = false
	burst_authoritative = false
	set_physics_process(false)
	turret_sprite.play(&"idle")
	_schedule_aim_return()


func _cancel_burst(restart_idle: bool) -> void:
	var was_active := burst_active
	burst_active = false
	burst_authoritative = false
	burst_elapsed_seconds = 0.0
	burst_next_shot_index = 0
	active_burst_shot_count = configured_burst_count
	burst_action_id = 0
	set_physics_process(false)
	if turret_sprite != null:
		turret_sprite.play(&"idle")
	if was_active:
		tracer_fade.stop()
		tracer.visible = false
		muzzle_flash_sprite.stop()
		muzzle_flash_sprite.visible = false
		muzzle_emission_overlay.stop()
		muzzle_emission_overlay.visible = false
	if restart_idle:
		_schedule_aim_return()


func _select_nearest_visible_enemy() -> Enemy:
	_target_candidates.clear()
	if combat_runtime == null or not is_instance_valid(combat_runtime):
		return null
	# The common open-field case needs only the nearest indexed candidate. The
	# index's max_count=1 path performs one linear selection instead of sorting
	# every enemy in range. If that candidate is obstructed, the adaptive exact
	# fallback below avoids sorting unless several nearer targets are also hidden.
	combat_runtime.query_combat_targets_into(
		global_position,
		configured_attack_range,
		_target_candidates,
		1
	)
	if not _target_candidates.is_empty():
		var nearest := _target_candidates[0]
		if _is_valid_target(nearest) and _is_enemy_first_hitscan_collision(nearest):
			return nearest
		# The first exact candidate was blocked. Collect the radius once without
		# sorting, discard that same nearest entry, then test a few more exact
		# minima linearly. This keeps the common one-wall case O(n) while the sorted
		# tail below bounds an arbitrarily large blocked group at O(n log n).
		combat_runtime.query_combat_targets_unordered_into(
			global_position,
			configured_attack_range,
			_target_candidates
		)
		CombatTargetIndex.take_nearest_candidate(
			_target_candidates,
			global_position
		)
		var linear_attempts := mini(
			LINEAR_BLOCKED_TARGET_ATTEMPTS,
			_target_candidates.size()
		)
		for _attempt_index in range(linear_attempts):
			var candidate := CombatTargetIndex.take_nearest_candidate(
				_target_candidates,
				global_position
			)
			if _is_valid_target(candidate) and _is_enemy_first_hitscan_collision(candidate):
				return candidate
		CombatTargetIndex.sort_candidates_by_distance(
			_target_candidates,
			global_position
		)
		for candidate in _target_candidates:
			if not _is_valid_target(candidate):
				continue
			if not _is_enemy_first_hitscan_collision(candidate):
				continue
			# The untouched tail retains stable distance/instance-id ordering.
			return candidate
	return null


func _is_enemy_first_hitscan_collision(enemy: Enemy) -> bool:
	if not _is_valid_target(enemy):
		return false
	var ray_start := aim_pivot.global_position
	_set_ray_query_segment(
		ray_start,
		enemy.global_position
	)
	var result := get_world_2d().direct_space_state.intersect_ray(_ray_query)
	if result.is_empty():
		return false
	var collider := result.get("collider") as Node
	if collider == enemy or (collider != null and enemy.is_ancestor_of(collider)):
		return true
	var shield := collider as ProjectileShieldArea
	return (
		shield != null
		and shield.is_active()
		and shield.get_owner_enemy() == enemy
	)


func _is_valid_target(enemy: Enemy) -> bool:
	return (
		enemy != null
		and is_instance_valid(enemy)
		and enemy.is_inside_tree()
		and not enemy.is_dead
	)


func _point_aim_at_direction(direction: Vector2) -> void:
	if direction == Vector2.ZERO:
		return
	aim_pivot.global_rotation = direction.angle() - forward_marker.position.angle()


func _on_idle_aim_timer_timeout() -> void:
	if not idle_aim_active or is_dead or burst_active:
		return
	_apply_idle_aim_step()
	idle_aim_timer.start(_sample_idle_aim_interval())


func _start_idle_aim() -> void:
	if is_dead or burst_active or idle_aim_active:
		return
	_cancel_aim_return()
	idle_aim_active = true
	idle_aim_last_direction = 0
	aim_pivot.rotation = idle_aim_center_rotation
	idle_aim_timer.start(_sample_idle_aim_interval())


func _stop_idle_aim() -> void:
	idle_aim_timer.stop()
	idle_aim_active = false
	idle_aim_last_direction = 0


func _schedule_aim_return(
	delay_seconds: float = AIM_RETURN_DELAY_SECONDS
) -> void:
	if is_dead or burst_active:
		return
	# Hold the last combat direction without any per-frame script work. Only the
	# short visible recenter transition below uses a native SceneTreeTween.
	_stop_idle_aim()
	_cancel_aim_return()
	aim_return_timer.start(maxf(delay_seconds, 0.001))


func _cancel_aim_return() -> void:
	aim_return_timer.stop()
	if _aim_return_tween != null:
		_aim_return_tween.kill()
		_aim_return_tween = null


func _on_aim_return_timer_timeout() -> void:
	if is_dead or burst_active:
		return
	_cancel_aim_return()
	var shortest_center_rotation := (
		aim_pivot.rotation
		+ angle_difference(aim_pivot.rotation, idle_aim_center_rotation)
	)
	if is_zero_approx(shortest_center_rotation - aim_pivot.rotation):
		_finish_aim_return()
		return
	_aim_return_tween = create_tween()
	_aim_return_tween.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_OUT)
	_aim_return_tween.tween_property(
		aim_pivot,
		^"rotation",
		shortest_center_rotation,
		AIM_RETURN_DURATION_SECONDS
	)
	_aim_return_tween.finished.connect(_finish_aim_return)


func _finish_aim_return() -> void:
	_aim_return_tween = null
	if is_dead or burst_active:
		return
	aim_pivot.rotation = idle_aim_center_rotation
	_start_idle_aim()


func _apply_idle_aim_step() -> void:
	var direction := -idle_aim_last_direction
	if direction == 0:
		direction = 1 if idle_aim_random.randi_range(0, 1) == 1 else -1
	var target_offset := idle_aim_random.randf_range(
		IDLE_AIM_MIN_TARGET_OFFSET,
		IDLE_AIM_LIMIT
	)
	aim_pivot.rotation = idle_aim_center_rotation + target_offset * float(direction)
	idle_aim_last_direction = direction


func _sample_idle_aim_interval() -> float:
	return idle_aim_random.randf_range(IDLE_AIM_INTERVAL_MIN, IDLE_AIM_INTERVAL_MAX)


func set_idle_aim_random_seed(seed_value: int) -> void:
	idle_aim_random.seed = seed_value


func _on_muzzle_flash_animation_finished() -> void:
	if muzzle_flash_sprite.animation == &"flash":
		muzzle_flash_sprite.visible = false
		muzzle_emission_overlay.stop()
		muzzle_emission_overlay.visible = false


func _on_tracer_fade_animation_finished(animation_name: StringName) -> void:
	if animation_name == &"fade":
		tracer.visible = false
