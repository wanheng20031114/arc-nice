extends PlantDefense
class_name HydrangeaRainTower

const RUNTIME_STATE_SCHEMA := 1
const ATTACK_REDUCTION_STATUS_ID := &"hydrangea_attack_reduction"
const STATUS_SOURCE_NAMESPACE := 130_000_000
const AUTHORED_RAIN_RADIUS := 160.0
const RAIN_VISUAL_FADE_SECONDS := 0.28

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
@onready var bloom_animation_player: AnimationPlayer = $BloomAnimationPlayer
@onready var cycle_timer: Timer = $CycleTimer
@onready var rain_tick_timer: Timer = $RainTickTimer
@onready var rain_end_timer: Timer = $RainEndTimer
@onready var health_bar: PlantHealthBar = $HealthBar

var rain_config: HydrangeaRainTowerConfig = null
var enemy_candidates: Array[Enemy] = []
var plant_candidates: Array[PlantDefense] = []
var player_candidates: Array[Player] = []
var damage_amounts := PackedInt32Array()
var damage_hit_counts := PackedInt32Array()

var rain_active := false
var rain_action_id := 0
var cycle_started_at_seconds := 0.0
var rain_started_at_seconds := 0.0
var rain_ticks_remaining := 0
var rain_field_tween: Tween = null
var pending_proxy_cycle_elapsed_seconds := -1.0
var pending_proxy_rain_elapsed_seconds := -1.0


func _on_setup_completed() -> void:
	rain_config = config as HydrangeaRainTowerConfig
	if rain_config == null:
		push_error("HydrangeaRainTower requires HydrangeaRainTowerConfig.")
		return

	cycle_timer.wait_time = rain_config.rain_interval_seconds
	rain_tick_timer.wait_time = rain_config.rain_tick_interval_seconds
	rain_end_timer.wait_time = rain_config.rain_duration_seconds
	damage_amounts = PackedInt32Array([rain_config.magic_damage_per_tick])
	damage_hit_counts = PackedInt32Array([1])
	rain_field.scale = Vector2.ONE * (
		rain_config.rain_radius / AUTHORED_RAIN_RADIUS
	)
	rain_field.set_instance_shader_parameter(
		&"rain_seed",
		float(_get_effect_source_id() % 997) / 997.0
	)

	health_bar.setup(max_health, current_health)
	if not health_changed.is_connected(_on_health_changed):
		health_changed.connect(_on_health_changed)
	_set_flower_state(false)
	_hide_rain_visual_immediate()


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
	if is_multiplayer_proxy and pending_proxy_cycle_elapsed_seconds >= 0.0:
		initial_cycle_elapsed = pending_proxy_cycle_elapsed_seconds
	pending_proxy_cycle_elapsed_seconds = -1.0
	_set_cycle_elapsed(initial_cycle_elapsed)
	if is_multiplayer_proxy and pending_proxy_rain_elapsed_seconds >= 0.0:
		_begin_rain(pending_proxy_rain_elapsed_seconds)
	pending_proxy_rain_elapsed_seconds = -1.0


func _on_multiplayer_proxy_configured() -> void:
	# Proxies retain the synchronized visual cycle, but never execute a combat
	# tick or write authoritative health/status state.
	rain_tick_timer.stop()


func _on_removal_started(_mode: RemovalMode) -> void:
	cycle_timer.stop()
	rain_tick_timer.stop()
	rain_end_timer.stop()
	_stop_rain_field_tween()
	bloom_animation_player.stop()
	core_night_light.set_emission_allowed(false)
	core_glow.hide()
	health_bar.hide()
	_hide_rain_visual_immediate()
	rain_active = false
	cycle_started_at_seconds = 0.0
	rain_started_at_seconds = 0.0
	rain_ticks_remaining = 0
	pending_proxy_cycle_elapsed_seconds = -1.0
	pending_proxy_rain_elapsed_seconds = -1.0


func _on_health_changed(new_health: int, new_max_health: int) -> void:
	health_bar.set_health(new_health, new_max_health)


func _on_cycle_timer_timeout() -> void:
	if not is_operational or is_dead or is_removing or rain_config == null:
		return
	# Advance the intended anchor by exactly one configured interval instead of
	# resetting it to this rendered frame. Timer jitter therefore never
	# accumulates into a different Host/client rain phase.
	var scheduled_cycle_start := (
		cycle_started_at_seconds + rain_config.rain_interval_seconds
	)
	var callback_lateness := maxf(_now_seconds() - scheduled_cycle_start, 0.0)
	cycle_started_at_seconds = scheduled_cycle_start
	cycle_timer.start(maxf(
		rain_config.rain_interval_seconds - callback_lateness,
		0.01
	))
	if not is_multiplayer_proxy:
		rain_action_id += 1
	_begin_rain(minf(callback_lateness, rain_config.rain_duration_seconds))


func _on_rain_tick_timer_timeout() -> void:
	if not rain_active or is_multiplayer_proxy or rain_ticks_remaining <= 0:
		rain_tick_timer.stop()
		return
	_apply_authoritative_rain_tick()
	rain_ticks_remaining -= 1
	if rain_ticks_remaining <= 0:
		rain_tick_timer.stop()


func _on_rain_end_timer_timeout() -> void:
	_finish_rain()


func _begin_rain(elapsed_seconds: float) -> void:
	if rain_config == null:
		return
	if rain_active:
		_finish_rain()
	rain_active = true
	var safe_elapsed := clampf(
		elapsed_seconds,
		0.0,
		rain_config.rain_duration_seconds
	)
	rain_started_at_seconds = _now_seconds() - safe_elapsed
	rain_ticks_remaining = maxi(
		floori(
			rain_config.rain_duration_seconds
			/ rain_config.rain_tick_interval_seconds
			+ 0.0001
		),
		1
	)
	_show_rain_visual(safe_elapsed)
	rain_end_timer.start(
		maxf(rain_config.rain_duration_seconds - safe_elapsed, 0.01)
	)
	if is_multiplayer_proxy:
		rain_ticks_remaining = 0
		return
	_apply_authoritative_rain_tick()
	rain_ticks_remaining -= 1
	if rain_ticks_remaining <= 0:
		rain_tick_timer.stop()
		return
	var first_tick_delay := rain_config.rain_tick_interval_seconds
	if safe_elapsed > 0.0:
		first_tick_delay = (
			rain_config.rain_tick_interval_seconds
			- fposmod(safe_elapsed, rain_config.rain_tick_interval_seconds)
		)
	rain_tick_timer.start(maxf(first_tick_delay, 0.01))


func _finish_rain() -> void:
	if not rain_active:
		return
	rain_active = false
	rain_started_at_seconds = 0.0
	rain_ticks_remaining = 0
	rain_tick_timer.stop()
	rain_end_timer.stop()
	_set_flower_state(false)
	core_night_light.set_emission_strength(1.0)
	core_glow.scale = Vector2.ONE * 0.3
	bloom_animation_player.stop()
	upper_canopy.scale = Vector2.ONE
	_fade_out_rain_field()


func _apply_authoritative_rain_tick() -> void:
	if (
		is_multiplayer_proxy
		or not rain_active
		or rain_config == null
		or is_dead
		or is_removing
	):
		return
	var current_scene := get_tree().current_scene
	if current_scene == null:
		return

	current_scene.call(
		"query_combat_targets_unordered_into",
		global_position,
		rain_config.rain_radius,
		enemy_candidates
	)
	var effect_source_id := _get_effect_source_id()
	for enemy in enemy_candidates:
		if (
			enemy == null
			or not is_instance_valid(enemy)
			or enemy.is_dead
			or enemy.is_queued_for_deletion()
		):
			continue
		current_scene.call(
			"apply_authoritative_plant_enemy_damage_batch",
			effect_source_id,
			enemy,
			damage_amounts,
			damage_hit_counts,
			global_position.direction_to(enemy.global_position),
			EnemyConfig.DamageType.MAGIC
		)
		if enemy.is_dead:
			continue
		enemy.apply_collectible_status(
			ATTACK_REDUCTION_STATUS_ID,
			effect_source_id,
			rain_config.attack_reduction_duration_seconds,
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
		global_position,
		rain_config.rain_radius,
		plant_candidates
	)
	for plant in plant_candidates:
		if plant != null and is_instance_valid(plant):
			plant.receive_healing(rain_config.healing_per_tick, self)

	current_scene.call(
		"query_living_players_in_radius_into",
		global_position,
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


func _show_rain_visual(elapsed_seconds: float) -> void:
	_set_flower_state(true)
	rain_field.show()
	core_night_light.set_emission_strength(1.28)
	core_glow.scale = Vector2.ONE * 0.38
	var initial_intensity := clampf(
		elapsed_seconds / RAIN_VISUAL_FADE_SECONDS,
		0.0,
		1.0
	)
	_set_rain_intensity(initial_intensity)
	_stop_rain_field_tween()
	if initial_intensity < 1.0:
		rain_field_tween = create_tween()
		rain_field_tween.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_OUT)
		rain_field_tween.tween_method(
			_set_rain_intensity,
			initial_intensity,
			1.0,
			RAIN_VISUAL_FADE_SECONDS * (1.0 - initial_intensity)
		)
	if elapsed_seconds < 0.45:
		dew_burst.restart()
		dew_burst.emitting = true
		bloom_animation_player.play(&"bloom")
	else:
		upper_canopy.scale = Vector2.ONE


func _fade_out_rain_field() -> void:
	_stop_rain_field_tween()
	rain_field_tween = create_tween()
	rain_field_tween.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN)
	rain_field_tween.tween_method(
		_set_rain_intensity,
		float(rain_field.get_instance_shader_parameter(&"rain_intensity")),
		0.0,
		RAIN_VISUAL_FADE_SECONDS
	)
	rain_field_tween.tween_callback(rain_field.hide)


func _hide_rain_visual_immediate() -> void:
	_stop_rain_field_tween()
	_set_rain_intensity(0.0)
	rain_field.hide()
	dew_burst.emitting = false
	_set_flower_state(false)


func _set_flower_state(is_raining: bool) -> void:
	main_sprite.texture = rain_texture if is_raining else idle_texture
	upper_canopy.texture = (
		rain_upper_texture if is_raining else idle_upper_texture
	)


func _set_rain_intensity(value: float) -> void:
	rain_field.set_instance_shader_parameter(
		&"rain_intensity",
		clampf(value, 0.0, 1.0)
	)


func _stop_rain_field_tween() -> void:
	if rain_field_tween != null and rain_field_tween.is_valid():
		rain_field_tween.kill()
	rain_field_tween = null


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
	var received_action_id := maxi(int(state.get("rain_action_id", 0)), 0)
	var crossed_cycle_count := floori(
		received_cycle_elapsed / rain_config.rain_interval_seconds
	)
	rain_action_id = received_action_id + crossed_cycle_count
	var received_rain_elapsed := maxf(
		float(state.get("rain_elapsed_seconds", 0.0)),
		0.0
	)
	var corrected_cycle_elapsed := fposmod(
		received_cycle_elapsed,
		rain_config.rain_interval_seconds
	)
	var should_restore_rain := false
	var corrected_rain_elapsed := received_rain_elapsed
	if crossed_cycle_count > 0:
		corrected_rain_elapsed = corrected_cycle_elapsed
		should_restore_rain = (
			corrected_rain_elapsed < rain_config.rain_duration_seconds
		)
	else:
		should_restore_rain = (
			bool(state.get("rain_active", false))
			and corrected_rain_elapsed < rain_config.rain_duration_seconds
		)
	if not is_operational:
		# Ordinary remote placement snapshots arrive while both peers are still
		# constructing. Preserve the age already added by MpGame and consume it
		# when this proxy becomes operational instead of restarting a fresh 10 s
		# cycle from the client-side construction completion frame.
		pending_proxy_cycle_elapsed_seconds = received_cycle_elapsed
		pending_proxy_rain_elapsed_seconds = (
			corrected_rain_elapsed if should_restore_rain else -1.0
		)
		return
	_set_cycle_elapsed(received_cycle_elapsed)
	if should_restore_rain:
		_begin_rain(corrected_rain_elapsed)
	else:
		_finish_rain()


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


func _get_effect_source_id() -> int:
	var stable_id := int(get_meta(&"net_id", 0))
	if stable_id <= 0:
		stable_id = int(get_instance_id())
	return STATUS_SOURCE_NAMESPACE + absi(stable_id)


func _now_seconds() -> float:
	return Time.get_ticks_msec() / 1000.0
