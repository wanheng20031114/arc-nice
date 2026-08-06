extends Area2D
class_name TangoElectricSurgeField

signal finished(field: Node)

const FIELD_RADIUS := 72.0
const FIELD_DURATION_SECONDS := 8.0
const DAMAGE_TICK_INTERVAL_SECONDS := 1.0
const DAMAGE_TICK_COUNT := 8
const MIN_TIMER_WAIT_SECONDS := 0.001
const FIXED_MAGIC_DAMAGE := 20
const ENEMY_COLLISION_MASK := 4
const DAMAGE_TYPE := EnemyConfig.DamageType.MAGIC
const DAMAGE_SOURCE_TYPE: StringName = &"tango_electric_surge"
const VISUAL_ANIMATION: StringName = &"surge_loop"

@onready var field_visual: AnimatedSprite2D = $FieldVisual
@onready var collision_shape: CollisionShape2D = $CollisionShape2D
@onready var night_light: NightPointLight2D = $NightPointLight
@onready var damage_tick_timer: Timer = $DamageTickTimer
@onready var lifetime_timer: Timer = $LifetimeTimer

var owner_player: Player = null
var combat_runtime: CombatRuntimeBase = null
var gameplay_gateway: MultiplayerGameplayGateway = null
var zone_id: int = 0
var overlapping_enemies: Dictionary[int, Enemy] = {}
var completed_damage_tick_count: int = 0

var _configured := false
var _active := false
var _authoritative := false
var _requested_duration := FIELD_DURATION_SECONDS
var _slow_source_id: int = 0


func setup(
	initial_owner_player: Player,
	initial_zone_id: int,
	duration: float = FIELD_DURATION_SECONDS,
	authoritative: bool = true
) -> void:
	if _active:
		return
	if initial_zone_id <= 0:
		push_error("Tango electric surge field requires a non-zero zone id.")
		return
	owner_player = initial_owner_player
	zone_id = initial_zone_id
	_requested_duration = maxf(duration, 0.0)
	_authoritative = authoritative
	_configured = true
	if is_node_ready():
		_begin_field()


func setup_multiplayer_visual_only(
	initial_zone_id: int,
	remaining_duration: float = FIELD_DURATION_SECONDS
) -> void:
	setup(null, initial_zone_id, remaining_duration, false)


func bind_gameplay_context(
	runtime_context: CombatRuntimeBase,
	gateway: MultiplayerGameplayGateway
) -> void:
	combat_runtime = runtime_context
	gameplay_gateway = gateway


func _ready() -> void:
	visible = false
	_set_authoritative_monitoring(false)
	night_light.set_emission_allowed(false)
	if _configured:
		_begin_field()


func _exit_tree() -> void:
	_remove_all_slow_sources()
	overlapping_enemies.clear()


func finish() -> void:
	_finish_field()


func is_active() -> bool:
	return _active


func is_authoritative() -> bool:
	return _authoritative


func get_tracked_enemy_count() -> int:
	return overlapping_enemies.size()


func _begin_field() -> void:
	if _active or not _configured:
		return
	_active = true
	visible = true
	completed_damage_tick_count = 0
	_slow_source_id = get_instance_id()
	_start_field_visual_animation()
	night_light.set_emission_allowed(true)

	if _authoritative:
		# LifetimeTimer is the shared game-time clock for both lifetime and damage.
		# DamageTickTimer only wakes the field near the next scheduled second; a
		# long frame catches up every due pulse instead of shifting the remaining
		# schedule by one full second per callback.
		_set_authoritative_monitoring(true)
		lifetime_timer.start(FIELD_DURATION_SECONDS)
		damage_tick_timer.start(DAMAGE_TICK_INTERVAL_SECONDS)
		call_deferred("_collect_initial_overlaps")
		return

	_set_authoritative_monitoring(false)
	if _requested_duration <= 0.0:
		_finish_field()
		return
	lifetime_timer.start(_requested_duration)


func _start_field_visual_animation() -> void:
	var sprite_frames := field_visual.sprite_frames
	if (
		sprite_frames == null
		or not sprite_frames.has_animation(VISUAL_ANIMATION)
	):
		return
	var frame_count := sprite_frames.get_frame_count(VISUAL_ANIMATION)
	if frame_count <= 0:
		return
	var animation_speed := sprite_frames.get_animation_speed(VISUAL_ANIMATION)
	var elapsed_seconds := 0.0
	if not _authoritative:
		elapsed_seconds = FIELD_DURATION_SECONDS - clampf(
			_requested_duration,
			0.0,
			FIELD_DURATION_SECONDS
		)
	var elapsed_frames := elapsed_seconds * animation_speed
	var seeded_frame := posmod(zone_id, frame_count)
	var target_frame := posmod(
		seeded_frame + floori(elapsed_frames),
		frame_count
	)
	field_visual.play(VISUAL_ANIMATION)
	field_visual.set_frame_and_progress(
		target_frame,
		fposmod(elapsed_frames, 1.0)
	)


func _set_authoritative_monitoring(enabled: bool) -> void:
	collision_layer = 0
	collision_mask = ENEMY_COLLISION_MASK if enabled else 0
	monitorable = false
	if collision_shape != null:
		collision_shape.set_deferred(&"disabled", not enabled)
	set_deferred(&"monitoring", enabled)


func _collect_initial_overlaps() -> void:
	if not _active or not _authoritative or not monitoring:
		return
	for body in get_overlapping_bodies():
		_on_body_entered(body)


func _on_body_entered(body: Node2D) -> void:
	if not _active or not _authoritative:
		return
	var enemy := body as Enemy
	if (
		enemy == null
		or not is_instance_valid(enemy)
		or enemy.is_dead
		or enemy.is_multiplayer_proxy
	):
		return
	var enemy_id := enemy.get_instance_id()
	if overlapping_enemies.has(enemy_id):
		return
	overlapping_enemies[enemy_id] = enemy
	enemy.apply_electric_element_attachment()
	enemy.add_electric_surge_slow_source(_slow_source_id)


func _on_body_exited(body: Node2D) -> void:
	if not _authoritative:
		return
	var enemy := body as Enemy
	if enemy == null:
		return
	_remove_enemy(enemy.get_instance_id(), enemy)


func _on_damage_tick_timeout() -> void:
	if not _active or not _authoritative:
		return
	var elapsed_seconds := _get_authoritative_elapsed_seconds()
	_apply_scheduled_damage_through(elapsed_seconds)
	if completed_damage_tick_count >= DAMAGE_TICK_COUNT:
		_finish_field()
		return
	var next_tick_at := (
		float(completed_damage_tick_count + 1)
		* DAMAGE_TICK_INTERVAL_SECONDS
	)
	damage_tick_timer.start(maxf(
		next_tick_at - elapsed_seconds,
		MIN_TIMER_WAIT_SECONDS
	))


func _on_lifetime_timeout() -> void:
	if _active and _authoritative:
		# Timer signal order is not guaranteed when both timers expire during the
		# same long frame. The lifetime callback therefore owns the final catch-up.
		_apply_scheduled_damage_through(FIELD_DURATION_SECONDS)
	_finish_field()


func _get_authoritative_elapsed_seconds() -> float:
	if lifetime_timer == null or lifetime_timer.is_stopped():
		return FIELD_DURATION_SECONDS
	return clampf(
		FIELD_DURATION_SECONDS - lifetime_timer.time_left,
		0.0,
		FIELD_DURATION_SECONDS
	)


func _apply_scheduled_damage_through(elapsed_seconds: float) -> void:
	var due_tick_count := mini(
		floori(
			(clampf(elapsed_seconds, 0.0, FIELD_DURATION_SECONDS)
			+ MIN_TIMER_WAIT_SECONDS)
			/ DAMAGE_TICK_INTERVAL_SECONDS
		),
		DAMAGE_TICK_COUNT
	)
	while completed_damage_tick_count < due_tick_count:
		completed_damage_tick_count += 1
		_apply_damage_tick()


func _apply_damage_tick() -> void:
	if overlapping_enemies.is_empty():
		return
	var stale_enemy_ids: Array[int] = []
	for enemy_id in overlapping_enemies:
		var enemy := overlapping_enemies[enemy_id]
		if (
			enemy == null
			or not is_instance_valid(enemy)
			or enemy.is_dead
			or enemy.is_multiplayer_proxy
		):
			stale_enemy_ids.append(enemy_id)
			continue
		_apply_fixed_magic_damage(enemy)
	for enemy_id in stale_enemy_ids:
		_remove_enemy(enemy_id, overlapping_enemies.get(enemy_id) as Enemy)


func _apply_fixed_magic_damage(enemy: Enemy) -> void:
	var impact_direction := global_position.direction_to(enemy.global_position)
	if impact_direction == Vector2.ZERO:
		impact_direction = Vector2.DOWN
	if owner_player != null and is_instance_valid(owner_player):
		owner_player._apply_authoritative_collectible_enemy_damage(
			enemy,
			FIXED_MAGIC_DAMAGE,
			impact_direction,
			DAMAGE_TYPE,
			false
		)
		return
	if (
		combat_runtime != null
		and is_instance_valid(combat_runtime)
		and combat_runtime.runtime_mode == CombatRuntimeBase.RuntimeMode.SINGLEPLAYER
	):
		var request := DamageRequest.new(FIXED_MAGIC_DAMAGE, int(DAMAGE_TYPE))
		request.with_source(self, zone_id, DAMAGE_SOURCE_TYPE)
		request.with_directions(impact_direction)
		request.with_flag(CombatTypes.DamageFlag.SUPPRESS_HIT_PARTICLES, true)
		enemy.apply_combat_damage(request)
		return
	if gameplay_gateway != null and is_instance_valid(gameplay_gateway):
		gameplay_gateway.apply_collectible_enemy_damage(
			enemy,
			FIXED_MAGIC_DAMAGE,
			impact_direction,
			DAMAGE_TYPE,
			false
		)


func _remove_enemy(enemy_id: int, enemy: Enemy) -> void:
	if not overlapping_enemies.has(enemy_id):
		return
	overlapping_enemies.erase(enemy_id)
	if enemy != null and is_instance_valid(enemy):
		enemy.remove_electric_surge_slow_source(_slow_source_id)


func _remove_all_slow_sources() -> void:
	for enemy in overlapping_enemies.values():
		var affected_enemy := enemy as Enemy
		if affected_enemy != null and is_instance_valid(affected_enemy):
			affected_enemy.remove_electric_surge_slow_source(_slow_source_id)


func _finish_field() -> void:
	if not _active:
		return
	_active = false
	damage_tick_timer.stop()
	lifetime_timer.stop()
	_set_authoritative_monitoring(false)
	_remove_all_slow_sources()
	overlapping_enemies.clear()
	night_light.set_emission_allowed(false)
	field_visual.stop()
	visible = false
	finished.emit(self)
	queue_free()
