extends PlantDefense
class_name HydrangeaRainTower

const RUNTIME_STATE_SCHEMA := 2
const ATTACK_REDUCTION_STATUS_ID := &"hydrangea_attack_reduction"
const STATUS_SOURCE_NAMESPACE := 130_000_000
const AUTHORED_RAIN_RADIUS := 160.0
const RAIN_VISUAL_FADE_IN_SECONDS := 0.36
const RAIN_FIELD_DISSIPATE_SECONDS := 0.9
const TARGET_RAIN_START_DELAY_SECONDS := 0.32
const BLOOM_OPEN_TRANSITION_SECONDS := 0.24
const BLOOM_CLOSE_TRANSITION_SECONDS := 0.32
const GROUND_DEW_EMISSION_FADE_SECONDS := 1.0
const GROUND_DEW_DISSIPATE_SECONDS := 1.4
const IDLE_CORE_LIGHT_STRENGTH := 1.0
const BLOOM_CORE_LIGHT_STRENGTH := 1.9
const BLOOM_CORE_LIGHT_COLOR := Color(0.38, 0.44, 1.0, 1.0)
const IDLE_CORE_GLOW_SCALE := Vector2(0.3, 0.3)
const BLOOM_CORE_GLOW_SCALE := Vector2(0.38, 0.38)

@export_group("128像素双状态素材")
@export var idle_texture: Texture2D
@export var rain_texture: Texture2D
@export var idle_upper_texture: Texture2D
@export var rain_upper_texture: Texture2D

@onready var main_sprite: Sprite2D = $VisualRoot/MainSprite
@onready var upper_canopy: Sprite2D = $VisualRoot/UpperCanopy
@onready var core_glow: Sprite2D = $CoreGlow
@onready var core_night_light: NightPointLight2D = $CoreNightLight
@onready var rain_field: Polygon2D = $RainField
@onready var dew_burst: GPUParticles2D = $DewBurst
@onready var ground_dew_rise: GPUParticles2D = $GroundDewRise
@onready var bloom_animation_player: AnimationPlayer = $BloomAnimationPlayer
@onready var cycle_timer: Timer = $CycleTimer
@onready var rain_tick_timer: Timer = $RainTickTimer
@onready var rain_end_timer: Timer = $RainEndTimer
@onready var effect_end_timer: Timer = $EffectEndTimer
@onready var health_bar: PlantHealthBar = $HealthBar

var rain_config: HydrangeaRainTowerConfig = null
var plant_system = null
var heal_target_candidates: Array[PlantDefense] = []
var enemy_candidates: Array[Enemy] = []
var plant_candidates: Array[PlantDefense] = []
var player_candidates: Array[Player] = []
var damage_amounts := PackedInt32Array()
var damage_hit_counts := PackedInt32Array()

var rain_active := false
var effect_active := false
var rain_action_id := 0
var rain_target_global_position := Vector2.ZERO
var cycle_started_at_seconds := 0.0
var rain_started_at_seconds := 0.0
var effect_started_at_seconds := 0.0
var next_effect_tick_index := 0
var total_effect_tick_count := 0
var rain_field_tween: Tween = null
var bloom_visual_tween: Tween = null
var ground_dew_dissolve_tween: Tween = null
var rain_visual_intensity := 0.0
var bloom_visual_progress := 0.0
var idle_core_light_color := Color(0.62, 0.42, 1.0, 1.0)
var pending_proxy_cycle_elapsed_seconds := -1.0
var pending_proxy_rain_elapsed_seconds := -1.0
var pending_proxy_rain_target_position := Vector2.ZERO
var pending_proxy_has_rain := false
var pending_proxy_recorded_at_seconds := -1.0


func _on_setup_completed() -> void:
	rain_config = config as HydrangeaRainTowerConfig
	if rain_config == null:
		push_error("HydrangeaRainTower requires HydrangeaRainTowerConfig.")
		return

	cycle_timer.wait_time = rain_config.rain_interval_seconds
	rain_tick_timer.wait_time = rain_config.rain_tick_interval_seconds
	rain_end_timer.wait_time = rain_config.rain_duration_seconds
	effect_end_timer.wait_time = rain_config.effect_duration_seconds
	damage_amounts = PackedInt32Array([rain_config.magic_damage_per_tick])
	damage_hit_counts = PackedInt32Array([1])
	rain_field.scale = Vector2.ONE * (
		rain_config.rain_radius / AUTHORED_RAIN_RADIUS
	)
	var ground_particle_material := (
		ground_dew_rise.process_material as ParticleProcessMaterial
	)
	if ground_particle_material != null:
		ground_particle_material.emission_sphere_radius = rain_config.rain_radius
	var particle_visibility_margin := 28.0
	ground_dew_rise.visibility_rect = Rect2(
		Vector2.ONE * (-rain_config.rain_radius - particle_visibility_margin),
		Vector2.ONE * (
			(rain_config.rain_radius + particle_visibility_margin) * 2.0
		)
	)
	_set_action_rain_seed()
	idle_core_light_color = core_night_light.color

	health_bar.setup(max_health, current_health)
	if not health_changed.is_connected(_on_health_changed):
		health_changed.connect(_on_health_changed)
	_set_flower_state(false)
	_hide_rain_visual_immediate()


func set_plant_system(new_plant_system) -> void:
	if plant_system == new_plant_system:
		return
	_disconnect_plant_system_signals()
	plant_system = new_plant_system
	heal_target_candidates.clear()
	if plant_system == null or is_multiplayer_proxy:
		return
	if not plant_system.plant_placed.is_connected(_on_plant_roster_changed):
		plant_system.plant_placed.connect(_on_plant_roster_changed)
	if not plant_system.plant_removed.is_connected(_on_plant_roster_changed):
		plant_system.plant_removed.connect(_on_plant_roster_changed)
	_refresh_healable_building_cache()


func _disconnect_plant_system_signals() -> void:
	if plant_system == null or not is_instance_valid(plant_system):
		return
	if plant_system.plant_placed.is_connected(_on_plant_roster_changed):
		plant_system.plant_placed.disconnect(_on_plant_roster_changed)
	if plant_system.plant_removed.is_connected(_on_plant_roster_changed):
		plant_system.plant_removed.disconnect(_on_plant_roster_changed)


func _on_plant_roster_changed(_plant: PlantDefense) -> void:
	_refresh_healable_building_cache()


func _refresh_healable_building_cache() -> void:
	heal_target_candidates.clear()
	if (
		plant_system == null
		or rain_config == null
		or is_multiplayer_proxy
		or not is_inside_tree()
	):
		return
	plant_system.query_living_plants_in_logical_radius_into(
		global_position,
		rain_config.target_search_radius_cells,
		heal_target_candidates
	)


func _select_lowest_health_target() -> PlantDefense:
	var selected: PlantDefense = null
	var selected_health := 0
	var selected_stable_id := 0
	for candidate in heal_target_candidates:
		if (
			candidate == null
			or not is_instance_valid(candidate)
			or candidate.is_dead
			or candidate.is_removing
			or candidate.is_queued_for_deletion()
		):
			continue
		var candidate_stable_id := _get_plant_stable_id(candidate)
		if (
			selected == null
			or candidate.current_health < selected_health
			or (
				candidate.current_health == selected_health
				and candidate_stable_id < selected_stable_id
			)
		):
			selected = candidate
			selected_health = candidate.current_health
			selected_stable_id = candidate_stable_id
	return selected


func _on_construction_started() -> void:
	core_night_light.set_emission_allowed(false)
	core_glow.hide()
	_hide_rain_visual_immediate()


func _on_construction_finished(_was_animated: bool) -> void:
	core_glow.show()
	core_night_light.set_emission_allowed(true)


func _on_operational_started() -> void:
	if rain_config == null:
		return
	var initial_cycle_elapsed := 0.0
	var pending_age_seconds := 0.0
	if is_multiplayer_proxy and pending_proxy_recorded_at_seconds >= 0.0:
		pending_age_seconds = maxf(
			_now_seconds() - pending_proxy_recorded_at_seconds,
			0.0
		)
	if is_multiplayer_proxy and pending_proxy_cycle_elapsed_seconds >= 0.0:
		initial_cycle_elapsed = (
			pending_proxy_cycle_elapsed_seconds + pending_age_seconds
		)
	pending_proxy_cycle_elapsed_seconds = -1.0
	_set_cycle_elapsed(initial_cycle_elapsed)
	var aged_pending_rain_elapsed := (
		pending_proxy_rain_elapsed_seconds + pending_age_seconds
	)
	if (
		is_multiplayer_proxy
		and pending_proxy_has_rain
		and aged_pending_rain_elapsed >= 0.0
		and aged_pending_rain_elapsed < rain_config.rain_duration_seconds
	):
		_begin_rain_visual(
			pending_proxy_rain_target_position,
			aged_pending_rain_elapsed
		)
	pending_proxy_rain_elapsed_seconds = -1.0
	pending_proxy_rain_target_position = Vector2.ZERO
	pending_proxy_has_rain = false
	pending_proxy_recorded_at_seconds = -1.0


func _on_multiplayer_proxy_configured() -> void:
	rain_tick_timer.stop()
	effect_end_timer.stop()
	effect_active = false


func _on_removal_started(_mode: RemovalMode) -> void:
	cycle_timer.stop()
	rain_tick_timer.stop()
	rain_end_timer.stop()
	effect_end_timer.stop()
	_disconnect_plant_system_signals()
	heal_target_candidates.clear()
	_stop_rain_field_tween()
	bloom_animation_player.stop()
	core_night_light.set_emission_allowed(false)
	core_glow.hide()
	health_bar.hide()
	_hide_rain_visual_immediate()
	rain_active = false
	effect_active = false
	cycle_started_at_seconds = 0.0
	rain_started_at_seconds = 0.0
	effect_started_at_seconds = 0.0
	next_effect_tick_index = 0
	total_effect_tick_count = 0
	pending_proxy_cycle_elapsed_seconds = -1.0
	pending_proxy_rain_elapsed_seconds = -1.0
	pending_proxy_rain_target_position = Vector2.ZERO
	pending_proxy_has_rain = false
	pending_proxy_recorded_at_seconds = -1.0


func _on_health_changed(new_health: int, new_max_health: int) -> void:
	health_bar.set_health(new_health, new_max_health)


func _on_cycle_timer_timeout() -> void:
	if not is_operational or is_dead or is_removing or rain_config == null:
		return
	var scheduled_cycle_start := (
		cycle_started_at_seconds + rain_config.rain_interval_seconds
	)
	var callback_lateness := maxf(_now_seconds() - scheduled_cycle_start, 0.0)
	cycle_started_at_seconds = scheduled_cycle_start
	cycle_timer.start(maxf(
		rain_config.rain_interval_seconds - callback_lateness,
		0.01
	))
	if is_multiplayer_proxy:
		return
	var target := _select_lowest_health_target()
	if target == null:
		return
	rain_action_id += 1
	var action_elapsed := minf(
		callback_lateness,
		rain_config.effect_duration_seconds - 0.001
	)
	_begin_authoritative_rain(
		target.global_position,
		action_elapsed
	)
	_broadcast_rain_action(action_elapsed)


func _on_rain_tick_timer_timeout() -> void:
	if (
		not effect_active
		or is_multiplayer_proxy
		or next_effect_tick_index >= total_effect_tick_count
	):
		rain_tick_timer.stop()
		return
	_apply_authoritative_rain_tick(next_effect_tick_index)
	next_effect_tick_index += 1
	_schedule_next_effect_tick()


func _on_rain_end_timer_timeout() -> void:
	_finish_rain_visual()


func _on_effect_end_timer_timeout() -> void:
	_finish_gameplay_effect()


func _begin_authoritative_rain(
	target_position: Vector2,
	elapsed_seconds: float
) -> void:
	if rain_config == null or not target_position.is_finite():
		return
	if effect_active:
		_finish_gameplay_effect()
	var safe_elapsed := clampf(
		elapsed_seconds,
		0.0,
		rain_config.effect_duration_seconds - 0.001
	)
	effect_active = true
	rain_target_global_position = target_position
	effect_started_at_seconds = _now_seconds() - safe_elapsed
	total_effect_tick_count = maxi(
		ceili(
			rain_config.effect_duration_seconds
			/ rain_config.rain_tick_interval_seconds
			- 0.0001
		),
		1
	)
	var current_tick_index := mini(
		floori(safe_elapsed / rain_config.rain_tick_interval_seconds + 0.0001),
		total_effect_tick_count - 1
	)
	if safe_elapsed < rain_config.rain_duration_seconds:
		_begin_rain_visual(target_position, safe_elapsed)
	else:
		_finish_rain_visual()
	effect_end_timer.start(maxf(
		rain_config.effect_duration_seconds - safe_elapsed,
		0.01
	))
	_apply_authoritative_rain_tick(current_tick_index)
	next_effect_tick_index = current_tick_index + 1
	_schedule_next_effect_tick()


func _schedule_next_effect_tick() -> void:
	rain_tick_timer.stop()
	if (
		not effect_active
		or next_effect_tick_index >= total_effect_tick_count
		or rain_config == null
	):
		return
	var elapsed := maxf(_now_seconds() - effect_started_at_seconds, 0.0)
	var intended_elapsed := (
		float(next_effect_tick_index) * rain_config.rain_tick_interval_seconds
	)
	rain_tick_timer.start(maxf(intended_elapsed - elapsed, 0.01))


func _finish_gameplay_effect() -> void:
	effect_active = false
	effect_started_at_seconds = 0.0
	next_effect_tick_index = 0
	total_effect_tick_count = 0
	rain_tick_timer.stop()
	effect_end_timer.stop()


func _apply_authoritative_rain_tick(tick_index: int) -> void:
	if (
		is_multiplayer_proxy
		or not effect_active
		or rain_config == null
		or is_dead
		or is_removing
	):
		return
	var current_scene := get_tree().current_scene
	if current_scene == null:
		return
	var effect_remaining_seconds := (
		effect_started_at_seconds
		+ rain_config.effect_duration_seconds
		- _now_seconds()
	)
	if effect_remaining_seconds <= 0.0:
		return

	current_scene.call(
		"query_combat_targets_unordered_into",
		rain_target_global_position,
		rain_config.rain_radius,
		enemy_candidates
	)
	var effect_source_id := _get_effect_source_id()
	var deals_magic_damage := (
		float(tick_index) * rain_config.rain_tick_interval_seconds
		< rain_config.rain_duration_seconds - 0.0001
	)
	for enemy in enemy_candidates:
		if (
			enemy == null
			or not is_instance_valid(enemy)
			or enemy.is_dead
			or enemy.is_queued_for_deletion()
		):
			continue
		if deals_magic_damage:
			current_scene.call(
				"apply_authoritative_plant_enemy_damage_batch",
				effect_source_id,
				enemy,
				damage_amounts,
				damage_hit_counts,
				rain_target_global_position.direction_to(enemy.global_position),
				EnemyConfig.DamageType.MAGIC
			)
		if enemy.is_dead:
			continue
		enemy.apply_collectible_status(
			ATTACK_REDUCTION_STATUS_ID,
			effect_source_id,
			maxf(effect_remaining_seconds, 0.01),
			0,
			0.5,
			EnemyConfig.DamageType.MAGIC,
			1.0,
			0,
			1.0,
			rain_config.enemy_attack_damage_multiplier
		)

	current_scene.call(
		"query_living_plants_in_radius_into",
		rain_target_global_position,
		rain_config.rain_radius,
		plant_candidates
	)
	for plant in plant_candidates:
		if plant != null and is_instance_valid(plant):
			plant.receive_healing(rain_config.healing_per_tick, self)

	current_scene.call(
		"query_living_players_in_radius_into",
		rain_target_global_position,
		rain_config.rain_radius,
		player_candidates
	)
	for target_player in player_candidates:
		if target_player == null or not is_instance_valid(target_player):
			continue
		current_scene.call(
			"apply_authoritative_player_heal",
			target_player,
			rain_config.healing_per_tick
		)


func _begin_rain_visual(
	target_position: Vector2,
	elapsed_seconds: float
) -> void:
	if rain_config == null or not target_position.is_finite():
		return
	if rain_active:
		_finish_rain_visual()
	var safe_elapsed := clampf(
		elapsed_seconds,
		0.0,
		rain_config.rain_duration_seconds
	)
	if safe_elapsed >= rain_config.rain_duration_seconds:
		return
	rain_active = true
	rain_target_global_position = target_position
	rain_started_at_seconds = _now_seconds() - safe_elapsed
	rain_field.global_position = target_position
	ground_dew_rise.global_position = target_position
	_set_action_rain_seed()
	_show_rain_visual(safe_elapsed)
	rain_end_timer.start(maxf(
		rain_config.rain_duration_seconds - safe_elapsed,
		0.01
	))


func _finish_rain_visual() -> void:
	if not rain_active:
		return
	rain_active = false
	rain_started_at_seconds = 0.0
	rain_end_timer.stop()
	_begin_flower_close()
	_begin_rain_field_dissolve()
	_begin_ground_dew_dissolve()


func _show_rain_visual(elapsed_seconds: float) -> void:
	_begin_flower_open(elapsed_seconds)
	if elapsed_seconds < TARGET_RAIN_START_DELAY_SECONDS:
		_launch_dew_burst()
	_start_rain_field_timeline(elapsed_seconds)


func _start_rain_field_timeline(elapsed_seconds: float) -> void:
	_stop_rain_field_tween()
	_stop_ground_dew_dissolve_tween()
	_stop_particles_immediate(ground_dew_rise)
	_reset_ground_dew_visual_properties()
	_set_rain_intensity(0.0)
	rain_field.hide()
	var safe_elapsed := clampf(
		elapsed_seconds,
		0.0,
		rain_config.rain_duration_seconds
	)
	var fade_in_end := minf(
		TARGET_RAIN_START_DELAY_SECONDS + RAIN_VISUAL_FADE_IN_SECONDS,
		rain_config.rain_duration_seconds
	)
	var initial_intensity := 0.0
	if safe_elapsed >= TARGET_RAIN_START_DELAY_SECONDS:
		initial_intensity = 1.0
	if (
		safe_elapsed >= TARGET_RAIN_START_DELAY_SECONDS
		and safe_elapsed < fade_in_end
	):
		initial_intensity = (
			(safe_elapsed - TARGET_RAIN_START_DELAY_SECONDS)
			/ maxf(
				fade_in_end - TARGET_RAIN_START_DELAY_SECONDS,
				0.001
			)
		)
	rain_field_tween = create_tween()
	rain_field_tween.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
	var cursor := safe_elapsed
	if cursor < TARGET_RAIN_START_DELAY_SECONDS:
		rain_field_tween.tween_interval(
			TARGET_RAIN_START_DELAY_SECONDS - cursor
		)
		rain_field_tween.tween_callback(_start_target_rain_visual)
		cursor = TARGET_RAIN_START_DELAY_SECONDS
	else:
		_start_target_rain_visual()
		_set_rain_intensity(initial_intensity)
	if cursor < fade_in_end:
		rain_field_tween.tween_method(
			_set_rain_intensity,
			initial_intensity,
			1.0,
			fade_in_end - cursor
		)


func _start_target_rain_visual() -> void:
	rain_field.show()
	_prepare_ground_dew_rise_for_emission()


func _launch_dew_burst() -> void:
	dew_burst.rotation = 0.0
	dew_burst.restart()
	dew_burst.emitting = true


func _hide_rain_field_immediate() -> void:
	_stop_rain_field_tween()
	_set_rain_intensity(0.0)
	rain_field.hide()


func _begin_rain_field_dissolve() -> void:
	_stop_rain_field_tween()
	if not rain_field.visible or rain_visual_intensity <= 0.0001:
		_hide_rain_field_immediate()
		return
	rain_field_tween = create_tween()
	rain_field_tween.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
	rain_field_tween.tween_method(
		_set_rain_intensity,
		rain_visual_intensity,
		0.0,
		RAIN_FIELD_DISSIPATE_SECONDS
	)
	rain_field_tween.tween_callback(_complete_rain_field_dissolve)


func _complete_rain_field_dissolve() -> void:
	rain_field_tween = null
	_set_rain_intensity(0.0)
	rain_field.hide()


func _hide_rain_effect_nodes_immediate() -> void:
	_hide_rain_field_immediate()
	_stop_ground_dew_dissolve_tween()
	_stop_particles_immediate(ground_dew_rise)
	_reset_ground_dew_visual_properties()


func _hide_rain_visual_immediate() -> void:
	_hide_rain_effect_nodes_immediate()
	_stop_particles_immediate(dew_burst)
	_set_flower_state(false)


func _stop_particles_immediate(particles: GPUParticles2D) -> void:
	particles.emitting = false
	particles.restart()
	particles.emitting = false


func _begin_flower_open(elapsed_seconds: float) -> void:
	_stop_bloom_visual_tween()
	bloom_animation_player.stop()
	main_sprite.texture = rain_texture
	upper_canopy.texture = rain_upper_texture
	upper_canopy.self_modulate = Color.WHITE
	upper_canopy.scale = Vector2.ONE
	var safe_elapsed := maxf(elapsed_seconds, 0.0)
	var initial_progress := clampf(
		safe_elapsed / BLOOM_OPEN_TRANSITION_SECONDS,
		0.0,
		1.0
	)
	_set_bloom_visual_progress(initial_progress)
	if initial_progress < 1.0:
		_start_bloom_visual_tween(
			1.0,
			BLOOM_OPEN_TRANSITION_SECONDS - safe_elapsed
		)
	var bloom_animation_length := bloom_animation_player.get_animation(
		&"bloom"
	).length
	if safe_elapsed < bloom_animation_length:
		bloom_animation_player.play(&"bloom")
		bloom_animation_player.seek(safe_elapsed, true)


func _begin_flower_close() -> void:
	_stop_bloom_visual_tween()
	bloom_animation_player.stop()
	main_sprite.texture = idle_texture
	upper_canopy.texture = rain_upper_texture
	upper_canopy.self_modulate = Color.WHITE
	upper_canopy.scale = Vector2.ONE
	_start_bloom_visual_tween(0.0, BLOOM_CLOSE_TRANSITION_SECONDS)
	bloom_animation_player.play(&"close")


func _on_bloom_animation_finished(animation_name: StringName) -> void:
	if animation_name != &"close" or rain_active:
		return
	_complete_flower_close()


func _complete_flower_close() -> void:
	_stop_bloom_visual_tween()
	main_sprite.texture = idle_texture
	upper_canopy.texture = idle_upper_texture
	upper_canopy.self_modulate = Color.WHITE
	upper_canopy.scale = Vector2.ONE
	_set_bloom_visual_progress(0.0)


func _set_flower_state(is_raining: bool) -> void:
	_stop_bloom_visual_tween()
	bloom_animation_player.stop()
	main_sprite.texture = rain_texture if is_raining else idle_texture
	upper_canopy.texture = (
		rain_upper_texture if is_raining else idle_upper_texture
	)
	upper_canopy.self_modulate = Color.WHITE
	upper_canopy.scale = Vector2.ONE
	_set_bloom_visual_progress(1.0 if is_raining else 0.0)


func _set_bloom_visual_progress(value: float) -> void:
	bloom_visual_progress = clampf(value, 0.0, 1.0)
	core_night_light.color = (
		idle_core_light_color.lerp(
			BLOOM_CORE_LIGHT_COLOR,
			bloom_visual_progress
		)
	)
	core_night_light.set_emission_strength(
		lerpf(
			IDLE_CORE_LIGHT_STRENGTH,
			BLOOM_CORE_LIGHT_STRENGTH,
			bloom_visual_progress
		)
	)
	core_glow.scale = IDLE_CORE_GLOW_SCALE.lerp(
		BLOOM_CORE_GLOW_SCALE,
		bloom_visual_progress
	)


func _start_bloom_visual_tween(target_progress: float, duration: float) -> void:
	_stop_bloom_visual_tween()
	var safe_target := clampf(target_progress, 0.0, 1.0)
	var safe_duration := maxf(duration, 0.0)
	if safe_duration <= 0.0001:
		_set_bloom_visual_progress(safe_target)
		return
	bloom_visual_tween = create_tween()
	bloom_visual_tween.set_trans(Tween.TRANS_SINE).set_ease(
		Tween.EASE_IN_OUT
	)
	bloom_visual_tween.tween_method(
		_set_bloom_visual_progress,
		bloom_visual_progress,
		safe_target,
		safe_duration
	)


func _stop_bloom_visual_tween() -> void:
	if bloom_visual_tween != null and bloom_visual_tween.is_valid():
		bloom_visual_tween.kill()
	bloom_visual_tween = null


func _prepare_ground_dew_rise_for_emission() -> void:
	_stop_ground_dew_dissolve_tween()
	_reset_ground_dew_visual_properties()
	ground_dew_rise.restart()
	ground_dew_rise.emitting = true


func _begin_ground_dew_dissolve() -> void:
	_stop_ground_dew_dissolve_tween()
	if not ground_dew_rise.emitting:
		_reset_ground_dew_visual_properties()
		return
	ground_dew_dissolve_tween = create_tween()
	ground_dew_dissolve_tween.set_parallel(true)
	ground_dew_dissolve_tween.tween_property(
		ground_dew_rise,
		"amount_ratio",
		0.0,
		GROUND_DEW_EMISSION_FADE_SECONDS
	).set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
	ground_dew_dissolve_tween.tween_property(
		ground_dew_rise,
		"self_modulate:a",
		0.0,
		GROUND_DEW_DISSIPATE_SECONDS
	).set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
	ground_dew_dissolve_tween.chain().tween_callback(
		_complete_ground_dew_dissolve
	)


func _complete_ground_dew_dissolve() -> void:
	ground_dew_dissolve_tween = null
	_stop_particles_immediate(ground_dew_rise)
	_reset_ground_dew_visual_properties()


func _stop_ground_dew_dissolve_tween() -> void:
	if (
		ground_dew_dissolve_tween != null
		and ground_dew_dissolve_tween.is_valid()
	):
		ground_dew_dissolve_tween.kill()
	ground_dew_dissolve_tween = null


func _reset_ground_dew_visual_properties() -> void:
	ground_dew_rise.amount_ratio = 1.0
	ground_dew_rise.self_modulate = Color.WHITE


func _set_rain_intensity(value: float) -> void:
	rain_visual_intensity = clampf(value, 0.0, 1.0)
	rain_field.set_instance_shader_parameter(
		&"rain_intensity",
		rain_visual_intensity
	)


func _set_action_rain_seed() -> void:
	var source_seed := float(_get_effect_source_id() % 997) / 997.0
	var action_seed := float(rain_action_id % 251) / 251.0
	rain_field.set_instance_shader_parameter(
		&"rain_seed",
		fposmod(source_seed + action_seed, 1.0)
	)


func _stop_rain_field_tween() -> void:
	if rain_field_tween != null and rain_field_tween.is_valid():
		rain_field_tween.kill()
	rain_field_tween = null


func _broadcast_rain_action(action_elapsed_seconds: float) -> void:
	var current_scene := get_tree().current_scene
	var plant_net_id := int(get_meta(&"net_id", 0))
	if (
		current_scene == null
		or plant_net_id <= 0
		or not current_scene.has_method("queue_hydrangea_rain_visual")
	):
		return
	current_scene.call(
		"queue_hydrangea_rain_visual",
		plant_net_id,
		rain_action_id,
		rain_target_global_position,
		maxf(action_elapsed_seconds, 0.0)
	)


func play_multiplayer_rain_action(
	action_id: int,
	target_position: Vector2,
	elapsed_seconds: float
) -> void:
	if (
		not is_multiplayer_proxy
		or rain_config == null
		or action_id <= rain_action_id
		or not target_position.is_finite()
		or not is_finite(elapsed_seconds)
	):
		return
	rain_action_id = action_id
	if not is_operational:
		pending_proxy_cycle_elapsed_seconds = maxf(elapsed_seconds, 0.0)
		pending_proxy_has_rain = (
			elapsed_seconds < rain_config.rain_duration_seconds
		)
		pending_proxy_rain_elapsed_seconds = (
			maxf(elapsed_seconds, 0.0) if pending_proxy_has_rain else -1.0
		)
		pending_proxy_rain_target_position = target_position
		pending_proxy_recorded_at_seconds = _now_seconds()
		return
	_set_cycle_elapsed(maxf(elapsed_seconds, 0.0))
	if elapsed_seconds < rain_config.rain_duration_seconds:
		_begin_rain_visual(target_position, maxf(elapsed_seconds, 0.0))
	else:
		_finish_rain_visual()


func export_multiplayer_runtime_state() -> Dictionary:
	if rain_config == null:
		return {}
	var now_seconds := _now_seconds()
	var cycle_elapsed := 0.0
	if is_operational and cycle_started_at_seconds > 0.0:
		cycle_elapsed = clampf(
			now_seconds - cycle_started_at_seconds,
			0.0,
			rain_config.rain_interval_seconds
		)
	var state := {
		"schema": RUNTIME_STATE_SCHEMA,
		"cycle_elapsed_seconds": cycle_elapsed,
		"rain_active": rain_active,
		"rain_action_id": rain_action_id,
	}
	if rain_active and rain_started_at_seconds > 0.0:
		state["rain_elapsed_seconds"] = clampf(
			now_seconds - rain_started_at_seconds,
			0.0,
			rain_config.rain_duration_seconds
		)
		state["rain_target_position"] = rain_target_global_position
	return state


func apply_multiplayer_runtime_state(
	state: Dictionary,
	_mapped_sample_time: float
) -> void:
	if (
		not is_multiplayer_proxy
		or rain_config == null
		or int(state.get("schema", 0)) != RUNTIME_STATE_SCHEMA
	):
		return
	var received_cycle_elapsed := maxf(
		float(state.get("cycle_elapsed_seconds", 0.0)),
		0.0
	)
	if not is_finite(received_cycle_elapsed):
		return
	var received_action_id := maxi(int(state.get("rain_action_id", 0)), 0)
	if received_action_id < rain_action_id:
		return
	rain_action_id = received_action_id
	var received_rain_elapsed := maxf(
		float(state.get("rain_elapsed_seconds", 0.0)),
		0.0
	)
	var received_target: Vector2 = state.get(
		"rain_target_position",
		Vector2.ZERO
	)
	var should_restore_rain := (
		bool(state.get("rain_active", false))
		and is_finite(received_rain_elapsed)
		and received_target.is_finite()
		and received_rain_elapsed < rain_config.rain_duration_seconds
	)
	if not is_operational:
		pending_proxy_cycle_elapsed_seconds = received_cycle_elapsed
		pending_proxy_has_rain = should_restore_rain
		pending_proxy_rain_elapsed_seconds = (
			received_rain_elapsed if should_restore_rain else -1.0
		)
		pending_proxy_rain_target_position = received_target
		pending_proxy_recorded_at_seconds = _now_seconds()
		return
	_set_cycle_elapsed(received_cycle_elapsed)
	if should_restore_rain:
		_begin_rain_visual(received_target, received_rain_elapsed)
	else:
		_finish_rain_visual()


func _set_cycle_elapsed(elapsed_seconds: float) -> void:
	if rain_config == null:
		return
	var cycle_elapsed := fposmod(
		maxf(elapsed_seconds, 0.0),
		rain_config.rain_interval_seconds
	)
	cycle_started_at_seconds = _now_seconds() - cycle_elapsed
	cycle_timer.start(maxf(
		rain_config.rain_interval_seconds - cycle_elapsed,
		0.01
	))


func _get_plant_stable_id(plant: PlantDefense) -> int:
	var stable_id := int(plant.get_meta(&"net_id", 0))
	if stable_id <= 0:
		stable_id = int(plant.get_instance_id())
	return stable_id


func _get_effect_source_id() -> int:
	var stable_id := int(get_meta(&"net_id", 0))
	if stable_id <= 0:
		stable_id = int(get_instance_id())
	return STATUS_SOURCE_NAMESPACE + absi(stable_id)


func _now_seconds() -> float:
	return Time.get_ticks_msec() / 1000.0
