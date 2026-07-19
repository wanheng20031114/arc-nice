extends Node2D
class_name BambooMortarShell

signal projectile_finished(projectile_id: int, projectile: Node)

const AUDIO_LIMITER := preload(
	"res://scene/plant_defense/plant_attack_audio_limiter.gd"
)
const FLIGHT_DURATION_SECONDS := 1.0
const EXPLOSION_FRAME_COUNT := 8
const EXPLOSION_FPS := 14.0
const EXPLOSION_DURATION_SECONDS := (
	float(EXPLOSION_FRAME_COUNT) / EXPLOSION_FPS
)
const TOTAL_VISUAL_DURATION_SECONDS := (
	FLIGHT_DURATION_SECONDS + EXPLOSION_DURATION_SECONDS
)
const INNER_RADIUS := 16.0
const OUTER_RADIUS := 32.0
const INNER_RADIUS_SQUARED := INNER_RADIUS * INNER_RADIUS
const OUTER_RADIUS_SQUARED := OUTER_RADIUS * OUTER_RADIUS
const DEFAULT_INNER_DAMAGE := 100
const DEFAULT_OUTER_DAMAGE := 50

@onready var visual: AnimatedSprite2D = $Visual
@onready var impact_audio: AudioStreamPlayer2D = $ImpactAudio

var start_position := Vector2.ZERO
var landing_position := Vector2.ZERO
var flight_elapsed_seconds := 0.0
var arc_height := 24.0
var inner_damage := DEFAULT_INNER_DAMAGE
var outer_damage := DEFAULT_OUTER_DAMAGE
var authoritative_damage := true
var damage_source_id := 0
var projectile_id := 0
var pool_active := true

var _has_impacted := false
var _combat_runtime: Node = null
var _explosion_targets: Array[Enemy] = []


func _ready() -> void:
	add_to_group(&"runtime_projectiles")
	pool_active = not has_meta(SessionObjectPool.POOL_OWNER_META)
	if pool_active:
		_reset_visual_state()
	else:
		set_physics_process(false)


func on_pool_acquired(_generation: int) -> void:
	pool_active = true
	_reset_visual_state()


func on_pool_released(_generation: int) -> void:
	pool_active = false
	_explosion_targets.clear()
	_has_impacted = true
	set_physics_process(false)
	if visual != null:
		visual.stop()
		visual.visible = false
	if impact_audio != null:
		impact_audio.stop()


func setup(
	new_start_position: Vector2,
	new_landing_position: Vector2,
	new_inner_damage: int = DEFAULT_INNER_DAMAGE,
	new_outer_damage: int = DEFAULT_OUTER_DAMAGE,
	can_apply_damage: bool = true,
	new_damage_source_id: int = 0,
	initial_elapsed_seconds: float = 0.0
) -> void:
	pool_active = true
	start_position = new_start_position
	landing_position = new_landing_position
	inner_damage = maxi(new_inner_damage, 0)
	outer_damage = maxi(new_outer_damage, 0)
	authoritative_damage = can_apply_damage
	damage_source_id = maxi(new_damage_source_id, 0)
	flight_elapsed_seconds = clampf(
		initial_elapsed_seconds,
		0.0,
		TOTAL_VISUAL_DURATION_SECONDS
	)
	arc_height = clampf(
		start_position.distance_to(landing_position) * 0.35,
		24.0,
		48.0
	)
	_combat_runtime = get_tree().current_scene
	_has_impacted = flight_elapsed_seconds >= FLIGHT_DURATION_SECONDS
	if flight_elapsed_seconds >= TOTAL_VISUAL_DURATION_SECONDS:
		_retire()
		return
	if _has_impacted:
		global_position = landing_position
		_begin_explosion_visual(
			flight_elapsed_seconds - FLIGHT_DURATION_SECONDS
		)
		return
	visual.visible = true
	visual.rotation = 0.0
	visual.play(&"flight")
	_update_flight_position()
	set_physics_process(true)


func setup_multiplayer(
	new_projectile_id: int,
	_owner_peer_id: int,
	_source_type: StringName
) -> void:
	projectile_id = maxi(new_projectile_id, 0)


func _physics_process(delta: float) -> void:
	if not pool_active or _has_impacted:
		set_physics_process(false)
		return
	flight_elapsed_seconds += maxf(delta, 0.0)
	if flight_elapsed_seconds >= FLIGHT_DURATION_SECONDS:
		_impact()
		return
	_update_flight_position()


func _update_flight_position() -> void:
	var progress := clampf(
		flight_elapsed_seconds / FLIGHT_DURATION_SECONDS,
		0.0,
		1.0
	)
	global_position = (
		start_position.lerp(landing_position, progress)
		+ Vector2.UP * sin(PI * progress) * arc_height
	)
	visual.rotation = lerpf(-0.35, 0.35, progress)


func _impact() -> void:
	if _has_impacted or not pool_active:
		return
	_has_impacted = true
	flight_elapsed_seconds = FLIGHT_DURATION_SECONDS
	global_position = landing_position
	set_physics_process(false)
	if authoritative_damage:
		_apply_explosion_damage()
	AUDIO_LIMITER.play_burst(impact_audio)
	_begin_explosion_visual(0.0)


func _begin_explosion_visual(elapsed_seconds: float) -> void:
	visual.rotation = 0.0
	if (
		visual.sprite_frames == null
		or not visual.sprite_frames.has_animation(&"explosion")
	):
		_retire()
		return
	var safe_elapsed := maxf(elapsed_seconds, 0.0)
	if safe_elapsed >= EXPLOSION_DURATION_SECONDS:
		_retire()
		return
	var frame_position := safe_elapsed * EXPLOSION_FPS
	var frame_index := clampi(
		floori(frame_position),
		0,
		EXPLOSION_FRAME_COUNT - 1
	)
	visual.visible = true
	visual.play(&"explosion")
	visual.set_frame_and_progress(
		frame_index,
		clampf(frame_position - float(frame_index), 0.0, 0.999)
	)


func _apply_explosion_damage() -> void:
	if (
		_combat_runtime != null
		and is_instance_valid(_combat_runtime)
		and _combat_runtime.has_method(
			"queue_bamboo_mortar_explosion"
		)
	):
		# A runtime that owns the authoritative queue also owns rejection. Do
		# not bypass a disabled/rejected service with synchronous direct damage.
		_combat_runtime.call(
			"queue_bamboo_mortar_explosion",
			landing_position,
			INNER_RADIUS,
			OUTER_RADIUS,
			inner_damage,
			outer_damage,
			damage_source_id
		)
		return
	_apply_explosion_damage_sync_for_fixture()


func _apply_explosion_damage_sync_for_fixture() -> void:
	_explosion_targets.clear()
	if (
		_combat_runtime == null
		or not is_instance_valid(_combat_runtime)
		or not _combat_runtime.has_method(
			"query_combat_targets_unordered_into"
		)
	):
		return
	_combat_runtime.call(
		"query_combat_targets_unordered_into",
		landing_position,
		OUTER_RADIUS,
		_explosion_targets
	)
	for enemy in _explosion_targets:
		if (
			enemy == null
			or not is_instance_valid(enemy)
			or not enemy.is_inside_tree()
			or enemy.is_dead
		):
			continue
		var distance_squared := landing_position.distance_squared_to(
			enemy.global_position
		)
		if distance_squared > OUTER_RADIUS_SQUARED:
			continue
		var applied_damage := (
			inner_damage
			if distance_squared <= INNER_RADIUS_SQUARED
			else outer_damage
		)
		if applied_damage <= 0:
			continue
		var impact_direction := landing_position.direction_to(
			enemy.global_position
		)
		if impact_direction == Vector2.ZERO:
			impact_direction = Vector2.UP
		if _combat_runtime.has_method(
			"apply_authoritative_plant_enemy_damage"
		):
			_combat_runtime.call(
				"apply_authoritative_plant_enemy_damage",
				damage_source_id,
				enemy,
				applied_damage,
				impact_direction,
				EnemyConfig.DamageType.PHYSICAL
			)
		else:
			enemy.apply_damage(
				applied_damage,
				impact_direction,
				EnemyConfig.DamageType.PHYSICAL
			)
	_explosion_targets.clear()


func _on_visual_animation_finished() -> void:
	if visual.animation == &"explosion":
		_retire()


func _retire() -> void:
	if not pool_active:
		return
	pool_active = false
	set_physics_process(false)
	projectile_finished.emit(projectile_id, self)
	if SessionObjectPool.release_to_owner(self):
		return
	queue_free()


func _reset_visual_state() -> void:
	start_position = Vector2.ZERO
	landing_position = Vector2.ZERO
	flight_elapsed_seconds = 0.0
	arc_height = 24.0
	inner_damage = DEFAULT_INNER_DAMAGE
	outer_damage = DEFAULT_OUTER_DAMAGE
	authoritative_damage = true
	damage_source_id = 0
	projectile_id = 0
	_has_impacted = false
	_combat_runtime = null
	_explosion_targets.clear()
	set_physics_process(false)
	if visual != null:
		visual.stop()
		visual.animation = &"flight"
		visual.frame = 0
		visual.frame_progress = 0.0
		visual.rotation = 0.0
		visual.visible = false
	if impact_audio != null:
		impact_audio.stop()
