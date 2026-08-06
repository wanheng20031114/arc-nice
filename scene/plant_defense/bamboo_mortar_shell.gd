extends Node2D
class_name BambooMortarShell

signal projectile_finished(projectile_id: int, projectile: Node)

const EXPLOSION_AUDIO_LIMITER := preload(
	"res://scene/explosion_audio_limiter.gd"
)
const SPATIAL_AUDIO_VOICE_LIMITER := preload(
	"res://scene/spatial_audio_voice_limiter.gd"
)
const NIGHT_VFX_FLASH_POOL := preload(
	"res://scene/lighting/night_vfx_flash_pool.gd"
)
const PROJECTILE_SPEED_PIXELS_PER_SECOND := 300.0
const MIN_FLIGHT_DURATION_SECONDS := 0.28
const MAX_FLIGHT_DURATION_SECONDS := 0.55
const ARC_HEIGHT_DISTANCE_FACTOR := 0.25
const MIN_ARC_HEIGHT := 18.0
const MAX_ARC_HEIGHT := 36.0
const SHADOW_START_GROUND_OFFSET := Vector2(0.0, 12.0)
const SHADOW_APEX_ALPHA_FACTOR := 0.45
const EXPLOSION_FRAME_COUNT := 8
const EXPLOSION_FPS := 14.0
const EXPLOSION_DURATION_SECONDS := (
	float(EXPLOSION_FRAME_COUNT) / EXPLOSION_FPS
)
const INNER_RADIUS := 16.0
const OUTER_RADIUS := 32.0
const INNER_RADIUS_SQUARED := INNER_RADIUS * INNER_RADIUS
const OUTER_RADIUS_SQUARED := OUTER_RADIUS * OUTER_RADIUS
const DEFAULT_INNER_DAMAGE := 140
const DEFAULT_OUTER_DAMAGE := 70

@onready var visual: AnimatedSprite2D = $Visual
@onready var projectile_halo: Sprite2D = $Visual/ProjectileHalo
@onready var emission_overlay: AnimatedSprite2D = $Visual/EmissionOverlay
@onready var ground_shadow: Polygon2D = $GroundShadow
@onready var impact_audio: AudioStreamPlayer2D = $ImpactAudio

var start_position := Vector2.ZERO
var landing_position := Vector2.ZERO
var shadow_start_position := Vector2.ZERO
var flight_elapsed_seconds := 0.0
var flight_duration_seconds := MAX_FLIGHT_DURATION_SECONDS
var arc_height := MIN_ARC_HEIGHT
var inner_damage := DEFAULT_INNER_DAMAGE
var outer_damage := DEFAULT_OUTER_DAMAGE
var authoritative_damage := true
var damage_source_id := 0
var projectile_id := 0
var pool_active := true

var _has_impacted := false
var _combat_runtime: CombatRuntimeBase = null
var _tower_multiplayer_mode_adapter: TowerPlantGameplayPort = null
var _explosion_targets: Array[Enemy] = []
var _explosion_completion_pending := false
var _explosion_visual_done := true
var _explosion_audio_done := true


static func get_flight_duration_seconds(
	new_start_position: Vector2,
	new_landing_position: Vector2
) -> float:
	return clampf(
		new_start_position.distance_to(new_landing_position)
		/ PROJECTILE_SPEED_PIXELS_PER_SECOND,
		MIN_FLIGHT_DURATION_SECONDS,
		MAX_FLIGHT_DURATION_SECONDS
	)


static func get_total_visual_duration_seconds(
	new_start_position: Vector2,
	new_landing_position: Vector2
) -> float:
	return (
		get_flight_duration_seconds(
			new_start_position,
			new_landing_position
		)
		+ EXPLOSION_DURATION_SECONDS
	)


func _ready() -> void:
	add_to_group(&"runtime_projectiles")
	impact_audio.set_meta(
		SPATIAL_AUDIO_VOICE_LIMITER.VOICE_PREEMPTED_CALLBACK_META,
		_on_impact_audio_preempted
	)
	pool_active = not has_meta(SessionObjectPool.POOL_OWNER_META)
	if pool_active:
		_reset_visual_state()
	else:
		set_physics_process(false)


func bind_gameplay_context(
	runtime_instance: CombatRuntimeBase,
	mode_adapter: TowerPlantGameplayPort
) -> void:
	_combat_runtime = runtime_instance
	_tower_multiplayer_mode_adapter = mode_adapter


func on_pool_acquired(_generation: int) -> void:
	pool_active = true
	_reset_visual_state()


func on_pool_released(_generation: int) -> void:
	pool_active = false
	_combat_runtime = null
	_tower_multiplayer_mode_adapter = null
	_explosion_targets.clear()
	_has_impacted = true
	_explosion_completion_pending = false
	_explosion_visual_done = true
	_explosion_audio_done = true
	set_physics_process(false)
	if visual != null:
		visual.stop()
		visual.visible = false
		visual.position = Vector2.ZERO
	if emission_overlay != null:
		emission_overlay.stop()
		emission_overlay.visible = false
	if projectile_halo != null:
		projectile_halo.visible = false
	if ground_shadow != null:
		ground_shadow.visible = false
	if impact_audio != null:
		EXPLOSION_AUDIO_LIMITER.stop(impact_audio)


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
	shadow_start_position = (
		start_position + SHADOW_START_GROUND_OFFSET
	)
	var travel_distance := start_position.distance_to(landing_position)
	flight_duration_seconds = get_flight_duration_seconds(
		start_position,
		landing_position
	)
	var total_visual_duration_seconds := get_total_visual_duration_seconds(
		start_position,
		landing_position
	)
	inner_damage = maxi(new_inner_damage, 0)
	outer_damage = maxi(new_outer_damage, 0)
	authoritative_damage = can_apply_damage
	damage_source_id = maxi(new_damage_source_id, 0)
	flight_elapsed_seconds = clampf(
		initial_elapsed_seconds,
		0.0,
		total_visual_duration_seconds
	)
	arc_height = clampf(
		travel_distance * ARC_HEIGHT_DISTANCE_FACTOR,
		MIN_ARC_HEIGHT,
		MAX_ARC_HEIGHT
	)
	_has_impacted = (
		flight_elapsed_seconds >= flight_duration_seconds
	)
	if flight_elapsed_seconds >= total_visual_duration_seconds:
		_retire()
		return
	if _has_impacted:
		global_position = landing_position
		_start_explosion(
			flight_elapsed_seconds - flight_duration_seconds,
			false
		)
		return
	visual.visible = true
	projectile_halo.visible = true
	visual.rotation = 0.0
	visual.play(&"flight")
	_play_emission_animation(&"flight", 0, 0.0)
	ground_shadow.visible = true
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
	if flight_elapsed_seconds >= flight_duration_seconds:
		_impact()
		return
	_update_flight_position()


func _update_flight_position() -> void:
	var progress := clampf(
		flight_elapsed_seconds / flight_duration_seconds,
		0.0,
		1.0
	)
	var height_factor := 4.0 * progress * (1.0 - progress)
	var flight_base_position := start_position.lerp(
		landing_position,
		progress
	)
	global_position = shadow_start_position.lerp(
		landing_position,
		progress
	)
	visual.position = (
		flight_base_position
		- global_position
		+ Vector2.UP * height_factor * arc_height
	)
	visual.rotation = lerpf(-0.45, 0.45, progress)
	ground_shadow.modulate.a = lerpf(
		1.0,
		SHADOW_APEX_ALPHA_FACTOR,
		height_factor
	)


func _impact() -> void:
	if _has_impacted or not pool_active:
		return
	_has_impacted = true
	flight_elapsed_seconds = flight_duration_seconds
	global_position = landing_position
	visual.position = Vector2.ZERO
	ground_shadow.visible = false
	set_physics_process(false)
	if authoritative_damage:
		_apply_explosion_damage()
	_start_explosion(0.0, true)


func _start_explosion(
	elapsed_seconds: float,
	play_impact_audio: bool
) -> void:
	_explosion_completion_pending = true
	_explosion_visual_done = true
	_explosion_audio_done = true
	if play_impact_audio and impact_audio.stream != null:
		EXPLOSION_AUDIO_LIMITER.play(impact_audio)
		# The shared limiter can reject distant or over-budget voices.
		_explosion_audio_done = not impact_audio.playing
	_begin_explosion_visual(elapsed_seconds)
	NIGHT_VFX_FLASH_POOL.request_from(
		self,
		global_position,
		Color(1.0, 0.58, 0.24, 1.0),
		1.05,
		0.78,
		0.035,
		0.055,
		0.28,
		2,
		maxf(elapsed_seconds, 0.0)
	)
	_try_finish_explosion()


func _begin_explosion_visual(elapsed_seconds: float) -> void:
	ground_shadow.visible = false
	projectile_halo.visible = false
	visual.position = Vector2.ZERO
	visual.rotation = 0.0
	if (
		visual.sprite_frames == null
		or not visual.sprite_frames.has_animation(&"explosion")
	):
		visual.visible = false
		emission_overlay.visible = false
		return
	var safe_elapsed := maxf(elapsed_seconds, 0.0)
	if safe_elapsed >= EXPLOSION_DURATION_SECONDS:
		visual.visible = false
		emission_overlay.visible = false
		return
	var frame_position := safe_elapsed * EXPLOSION_FPS
	var frame_index := clampi(
		floori(frame_position),
		0,
		EXPLOSION_FRAME_COUNT - 1
	)
	_explosion_visual_done = false
	visual.visible = true
	visual.play(&"explosion")
	visual.set_frame_and_progress(
		frame_index,
		clampf(frame_position - float(frame_index), 0.0, 0.999)
	)
	_play_emission_animation(
		&"explosion",
		frame_index,
		clampf(frame_position - float(frame_index), 0.0, 0.999)
	)


func _apply_explosion_damage() -> void:
	if (
		_combat_runtime != null
		and is_instance_valid(_combat_runtime)
		and _tower_multiplayer_mode_adapter != null
		and is_instance_valid(_tower_multiplayer_mode_adapter)
	):
		# A runtime that owns the authoritative queue also owns rejection. Do
		# not bypass a disabled/rejected service with synchronous direct damage.
		_tower_multiplayer_mode_adapter.queue_bamboo_mortar_explosion(
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
	):
		return
	_combat_runtime.query_combat_targets_unordered_into(
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
		if (
			_tower_multiplayer_mode_adapter != null
			and is_instance_valid(_tower_multiplayer_mode_adapter)
		):
			_tower_multiplayer_mode_adapter.apply_authoritative_plant_enemy_damage(
				damage_source_id,
				enemy,
				applied_damage,
				impact_direction,
				EnemyConfig.DamageType.PHYSICAL
			)
	_explosion_targets.clear()


func _on_visual_animation_finished() -> void:
	if visual.animation == &"explosion":
		visual.stop()
		visual.visible = false
		emission_overlay.stop()
		emission_overlay.visible = false
		_explosion_visual_done = true
		_try_finish_explosion()


func _on_impact_audio_finished() -> void:
	if not _explosion_completion_pending:
		return
	_explosion_audio_done = true
	_try_finish_explosion()


func _on_impact_audio_preempted() -> void:
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
	shadow_start_position = Vector2.ZERO
	flight_elapsed_seconds = 0.0
	flight_duration_seconds = MAX_FLIGHT_DURATION_SECONDS
	arc_height = MIN_ARC_HEIGHT
	inner_damage = DEFAULT_INNER_DAMAGE
	outer_damage = DEFAULT_OUTER_DAMAGE
	authoritative_damage = true
	damage_source_id = 0
	projectile_id = 0
	_has_impacted = false
	_combat_runtime = null
	_tower_multiplayer_mode_adapter = null
	_explosion_targets.clear()
	_explosion_completion_pending = false
	_explosion_visual_done = true
	_explosion_audio_done = true
	set_physics_process(false)
	if visual != null:
		visual.stop()
		visual.animation = &"flight"
		visual.frame = 0
		visual.frame_progress = 0.0
		visual.position = Vector2.ZERO
		visual.rotation = 0.0
		visual.visible = false
	if emission_overlay != null:
		emission_overlay.stop()
		emission_overlay.animation = &"flight"
		emission_overlay.frame = 0
		emission_overlay.frame_progress = 0.0
		emission_overlay.visible = false
	if projectile_halo != null:
		projectile_halo.visible = true
	if ground_shadow != null:
		ground_shadow.visible = false
		ground_shadow.modulate = Color.WHITE
	if impact_audio != null:
		EXPLOSION_AUDIO_LIMITER.stop(impact_audio)


func _exit_tree() -> void:
	if impact_audio != null:
		EXPLOSION_AUDIO_LIMITER.stop(impact_audio)


func _play_emission_animation(
	animation_name: StringName,
	frame_index: int,
	frame_progress: float
) -> void:
	if (
		emission_overlay == null
		or emission_overlay.sprite_frames == null
		or not emission_overlay.sprite_frames.has_animation(animation_name)
	):
		return
	emission_overlay.visible = true
	emission_overlay.play(animation_name)
	emission_overlay.set_frame_and_progress(
		frame_index,
		clampf(frame_progress, 0.0, 0.999)
	)
