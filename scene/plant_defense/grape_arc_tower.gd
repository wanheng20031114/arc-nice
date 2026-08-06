extends PlantDefense
class_name GrapeArcTower

const AUDIO_LIMITER := preload(
	"res://scene/plant_defense/plant_attack_audio_limiter.gd"
)
const DEFAULT_ATTACK_INTERVAL := 1.4
const TARGET_RETRY_SECONDS := 0.18
const INITIAL_ATTACK_DELAY_MIN_SECONDS := 0.08
const ATTACK_PHASE_GOLDEN_RATIO := 0.61803398875
const ARC_POINT_COUNT := 7
const ARC_MAX_JITTER := 7.0
const IDLE_LIGHT_STRENGTH := 0.55
const CHARGED_LIGHT_STRENGTH := 3.2
const RELEASE_LIGHT_STRENGTH := 4.5
const IDLE_SCAN_INITIAL_DELAY_MIN_SECONDS := 0.75
const IDLE_SCAN_INITIAL_DELAY_SPREAD_SECONDS := 2.0
const IDLE_SCAN_COOLDOWN_SECONDS := 3.2
const IDLE_SCAN_TRAVEL_SECONDS := 0.72
const IDLE_SCAN_FADE_SECONDS := 0.16
const SIDE_GRAPE_UV_TOP := 22.0 / 64.0
const SIDE_GRAPE_UV_BOTTOM := 36.0 / 64.0
const FIRING_GRAPE_UV_TOP := 39.0 / 64.0
const FIRING_GRAPE_UV_BOTTOM := 53.0 / 64.0

enum AttackTimerMode {
	NONE,
	ATTACK_CYCLE,
	TARGET_RETRY,
}

@onready var support_sprite: Sprite2D = $VisualRoot/SupportSprite
@onready var grape_cluster_root: Node2D = $VisualRoot/GrapeClusterRoot
@onready var side_grapes_sprite: Sprite2D = (
	$VisualRoot/GrapeClusterRoot/SideGrapesSprite
)
@onready var side_charge_overlay: Sprite2D = (
	$VisualRoot/GrapeClusterRoot/SideChargeOverlay
)
@onready var firing_grape_root: Node2D = (
	$VisualRoot/GrapeClusterRoot/FiringGrapeRoot
)
@onready var firing_grapes_sprite: Sprite2D = (
	$VisualRoot/GrapeClusterRoot/FiringGrapeRoot/FiringGrapesSprite
)
@onready var firing_charge_overlay: Sprite2D = (
	$VisualRoot/GrapeClusterRoot/FiringGrapeRoot/FiringChargeOverlay
)
@onready var grape_arc_origin: Marker2D = $GrapeArcOrigin
@onready var grape_night_light: NightPointLight2D = $GrapeNightLight
@onready var arc_layer: Node2D = $ArcLayer
@onready var attack_animation_player: AnimationPlayer = $AttackAnimationPlayer
@onready var attack_timer: Timer = $AttackTimer
@onready var release_timer: Timer = $ReleaseTimer
@onready var idle_scan_timer: Timer = $IdleScanTimer
@onready var health_bar: PlantHealthBar = $HealthBar
@onready var zap_audio: AudioStreamPlayer2D = $ZapAudio

var arc_config: GrapeArcTowerConfig = null
var configured_attack_damage := 0
var configured_attack_range := 0.0
var configured_chain_jump_range := 0.0
var configured_max_chain_targets := 1
var attack_locked := false
var attack_timer_mode := AttackTimerMode.NONE
var attack_action_id := 0
var pending_primary_target: Enemy = null
var charge_tween: Tween = null
var flash_tween: Tween = null
var idle_scan_tween: Tween = null
var idle_scan_active := false
var _idle_scan_progress := 0.0
var _idle_scan_strength := 0.0
var _query_candidates: Array[Enemy] = []
var _chain_targets: Array[Enemy] = []
var _arc_glows: Array[Line2D] = []
var _arc_cores: Array[Line2D] = []


func _ready() -> void:
	super._ready()
	_arc_glows.assign([
		$ArcLayer/Arc0/Glow,
		$ArcLayer/Arc1/Glow,
		$ArcLayer/Arc2/Glow,
		$ArcLayer/Arc3/Glow,
	])
	_arc_cores.assign([
		$ArcLayer/Arc0/Core,
		$ArcLayer/Arc1/Core,
		$ArcLayer/Arc2/Core,
		$ArcLayer/Arc3/Core,
	])
	_configure_charge_overlay_uv_ranges()
	_hide_all_arcs()
	_set_charge_progress(0.0)
	_set_release_flash(0.0)
	_reset_idle_scan_shader()


func _configure_charge_overlay_uv_ranges() -> void:
	side_charge_overlay.set_instance_shader_parameter(
		&"charge_uv_top",
		SIDE_GRAPE_UV_TOP
	)
	side_charge_overlay.set_instance_shader_parameter(
		&"charge_uv_bottom",
		SIDE_GRAPE_UV_BOTTOM
	)
	firing_charge_overlay.set_instance_shader_parameter(
		&"charge_uv_top",
		FIRING_GRAPE_UV_TOP
	)
	firing_charge_overlay.set_instance_shader_parameter(
		&"charge_uv_bottom",
		FIRING_GRAPE_UV_BOTTOM
	)


func _on_setup_completed() -> void:
	arc_config = config as GrapeArcTowerConfig
	if arc_config == null:
		push_error("GrapeArcTower requires GrapeArcTowerConfig.")
		return
	configured_attack_damage = maxi(arc_config.attack_damage, 0)
	configured_attack_range = maxf(arc_config.attack_range, 0.0)
	configured_chain_jump_range = maxf(arc_config.chain_jump_range, 0.0)
	configured_max_chain_targets = clampi(
		arc_config.max_chain_targets,
		1,
		_arc_glows.size()
	)
	health_bar.setup(max_health, current_health)
	if not health_changed.is_connected(_on_health_changed):
		health_changed.connect(_on_health_changed)
	if not attack_interval_multiplier_changed.is_connected(
		_on_attack_interval_multiplier_changed
	):
		attack_interval_multiplier_changed.connect(
			_on_attack_interval_multiplier_changed
		)
	_cancel_idle_scan()
	_reset_attack_visuals()


func _on_construction_started() -> void:
	_cancel_idle_scan()
	side_charge_overlay.hide()
	firing_charge_overlay.hide()
	grape_night_light.set_emission_allowed(false)
	_hide_all_arcs()


func _on_construction_finished(_was_animated: bool) -> void:
	side_charge_overlay.show()
	firing_charge_overlay.show()
	grape_night_light.set_emission_allowed(true)
	grape_night_light.set_emission_strength(IDLE_LIGHT_STRENGTH)


func _on_operational_started() -> void:
	if arc_config == null:
		return
	var attack_interval := _get_effective_attack_interval()
	attack_timer_mode = AttackTimerMode.ATTACK_CYCLE
	attack_timer.wait_time = attack_interval
	attack_timer.start(calculate_initial_attack_delay_seconds(
		attack_interval,
		_get_attack_phase_identity()
	))
	_schedule_idle_scan(_get_initial_idle_scan_delay_seconds())


func _on_multiplayer_proxy_configured() -> void:
	# Proxy towers run the same net-id-phased timer and query replicated enemies
	# only for visuals. Damage remains strictly host-authoritative below.
	if is_operational:
		_on_operational_started()


func _on_removal_started(_mode: RemovalMode) -> void:
	attack_timer.stop()
	attack_timer_mode = AttackTimerMode.NONE
	release_timer.stop()
	_cancel_idle_scan()
	_stop_charge_tween()
	_stop_flash_tween()
	attack_animation_player.stop()
	zap_audio.stop()
	attack_locked = false
	pending_primary_target = null
	_query_candidates.clear()
	_chain_targets.clear()
	health_bar.hide()
	grape_night_light.set_emission_allowed(false)
	_reset_attack_visuals()


static func calculate_initial_attack_delay_seconds(
	attack_interval: float,
	phase_identity: int
) -> float:
	var safe_interval := maxf(attack_interval, 0.001)
	if safe_interval <= INITIAL_ATTACK_DELAY_MIN_SECONDS:
		return safe_interval
	var phase_window := safe_interval - INITIAL_ATTACK_DELAY_MIN_SECONDS
	return (
		INITIAL_ATTACK_DELAY_MIN_SECONDS
		+ fposmod(
			float(phase_identity)
			* ATTACK_PHASE_GOLDEN_RATIO
			* safe_interval,
			phase_window
		)
	)


func _get_attack_phase_identity() -> int:
	var network_identity := int(get_meta(&"net_id", 0))
	if network_identity > 0:
		return network_identity
	return int(hash(Vector2i(
		roundi(global_position.x),
		roundi(global_position.y)
	)))


func _get_initial_idle_scan_delay_seconds() -> float:
	return (
		IDLE_SCAN_INITIAL_DELAY_MIN_SECONDS
		+ fposmod(
			float(_get_attack_phase_identity())
			* ATTACK_PHASE_GOLDEN_RATIO
			* IDLE_SCAN_INITIAL_DELAY_SPREAD_SECONDS,
			IDLE_SCAN_INITIAL_DELAY_SPREAD_SECONDS
		)
	)


func _on_health_changed(new_health: int, new_max_health: int) -> void:
	health_bar.set_health(new_health, new_max_health)


func _get_authored_attack_interval() -> float:
	var authored_interval := (
		arc_config.get_attack_interval() if arc_config != null else 0.0
	)
	return authored_interval if authored_interval > 0.0 else DEFAULT_ATTACK_INTERVAL


func _get_effective_attack_interval() -> float:
	return get_effective_attack_interval(_get_authored_attack_interval())


func _on_attack_interval_multiplier_changed(
	previous_multiplier: float,
	current_multiplier: float
) -> void:
	if (
		not is_operational
		or is_dead
		or is_removing
		or attack_timer_mode != AttackTimerMode.ATTACK_CYCLE
	):
		return
	var authored_interval := _get_authored_attack_interval()
	var current_interval := authored_interval * current_multiplier
	PlantDefense.retime_attack_cycle_timer(
		attack_timer,
		authored_interval * previous_multiplier,
		current_interval
	)
	# This timer is one-shot; keep its authored cycle visible separately from the
	# scaled current time_left, matching the normal post-lock scheduling state.
	if not attack_timer.is_stopped():
		attack_timer.wait_time = current_interval


func _on_attack_timer_timeout() -> void:
	attack_timer_mode = AttackTimerMode.NONE
	if (
		not is_operational
		or is_dead
		or is_removing
		or arc_config == null
	):
		return
	if attack_locked:
		attack_timer_mode = AttackTimerMode.TARGET_RETRY
		attack_timer.start(TARGET_RETRY_SECONDS)
		return
	var target := _select_primary_target()
	if target == null:
		attack_timer_mode = AttackTimerMode.TARGET_RETRY
		attack_timer.start(TARGET_RETRY_SECONDS)
		return
	pending_primary_target = target
	_begin_charge()
	attack_timer_mode = AttackTimerMode.ATTACK_CYCLE
	attack_timer.start(_get_effective_attack_interval())


func _begin_charge() -> void:
	_cancel_idle_scan()
	attack_locked = true
	release_timer.stop()
	_stop_charge_tween()
	_stop_flash_tween()
	attack_animation_player.stop()
	grape_cluster_root.position = Vector2.ZERO
	grape_cluster_root.scale = Vector2.ONE
	firing_grape_root.position = Vector2.ZERO
	firing_grape_root.scale = Vector2.ONE
	_hide_all_arcs()
	_set_release_flash(0.0)
	_set_charge_progress(0.0)
	side_charge_overlay.show()
	firing_charge_overlay.show()
	charge_tween = create_tween()
	charge_tween.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN)
	charge_tween.tween_method(
		_set_charge_progress,
		0.0,
		1.0,
		arc_config.charge_seconds
	)
	release_timer.start(arc_config.charge_seconds)


func _on_release_timer_timeout() -> void:
	if not attack_locked or not is_operational or is_dead or is_removing:
		_finish_attack_cycle()
		return
	_set_charge_progress(1.0)
	var primary := pending_primary_target
	if not _is_primary_target_available(primary):
		primary = _select_primary_target()
	pending_primary_target = null
	if primary == null:
		_play_release_animation(false)
		return

	_build_chain(primary)
	if _chain_targets.is_empty():
		_play_release_animation(false)
		return

	attack_action_id += 1
	var target_positions := PackedVector2Array()
	for target in _chain_targets:
		target_positions.append(target.global_position)
	_show_chain_arcs(target_positions)
	if not is_multiplayer_proxy:
		_apply_authoritative_chain(target_positions)
	AUDIO_LIMITER.play_burst(zap_audio)
	_play_release_animation(true)


func _select_primary_target() -> Enemy:
	_query_candidates.clear()
	if (
		combat_runtime == null
		or not is_instance_valid(combat_runtime)
	):
		return null
	combat_runtime.query_combat_targets_into(
		global_position,
		configured_attack_range,
		_query_candidates,
		1
	)
	if _query_candidates.is_empty():
		return null
	var candidate := _query_candidates[0]
	return candidate if _is_primary_target_available(candidate) else null


func _is_primary_target_available(enemy: Enemy) -> bool:
	return (
		_is_valid_target(enemy)
		and global_position.distance_squared_to(enemy.global_position)
		<= configured_attack_range * configured_attack_range
	)


func _is_valid_target(enemy: Enemy) -> bool:
	return (
		enemy != null
		and is_instance_valid(enemy)
		and enemy.is_inside_tree()
		and not enemy.is_dead
		and not enemy.is_queued_for_deletion()
	)


func _build_chain(primary: Enemy) -> void:
	_chain_targets.clear()
	if not _is_primary_target_available(primary):
		return
	_chain_targets.append(primary)
	var current_target := primary
	while _chain_targets.size() < configured_max_chain_targets:
		_query_candidates.clear()
		combat_runtime.query_combat_targets_into(
			current_target.global_position,
			configured_chain_jump_range,
			_query_candidates,
			0
		)
		var next_target: Enemy = null
		for candidate in _query_candidates:
			if not _is_valid_target(candidate) or _chain_targets.has(candidate):
				continue
			next_target = candidate
			break
		if next_target == null:
			break
		_chain_targets.append(next_target)
		current_target = next_target


func _apply_authoritative_chain(target_positions: PackedVector2Array) -> void:
	var previous_position := grape_arc_origin.global_position
	var source_id := int(get_meta(&"net_id", get_instance_id()))
	for index in range(_chain_targets.size()):
		var target := _chain_targets[index]
		if not _is_valid_target(target):
			previous_position = target_positions[index]
			continue
		var impact_direction := previous_position.direction_to(
			target_positions[index]
		)
		if (
			combat_runtime != null
			and is_instance_valid(combat_runtime)
			and tower_multiplayer_mode_adapter != null
			and is_instance_valid(tower_multiplayer_mode_adapter)
		):
			tower_multiplayer_mode_adapter.apply_authoritative_plant_enemy_damage(
				source_id,
				target,
				configured_attack_damage,
				impact_direction,
				EnemyConfig.DamageType.MAGIC
			)
		previous_position = target_positions[index]


func _show_chain_arcs(target_positions: PackedVector2Array) -> void:
	_hide_all_arcs()
	var previous_position := grape_arc_origin.global_position
	var segment_count := mini(target_positions.size(), _arc_glows.size())
	for segment_index in range(segment_count):
		var current_position := target_positions[segment_index]
		var points := _make_arc_points(
			arc_layer.to_local(previous_position),
			arc_layer.to_local(current_position),
			segment_index
		)
		_arc_glows[segment_index].points = points
		_arc_cores[segment_index].points = points
		_arc_glows[segment_index].show()
		_arc_cores[segment_index].show()
		previous_position = current_position
	arc_layer.modulate = Color.WHITE
	arc_layer.show()


func _make_arc_points(
	start: Vector2,
	end: Vector2,
	segment_index: int
) -> PackedVector2Array:
	var result := PackedVector2Array()
	var span := end - start
	var distance := span.length()
	var perpendicular := span.normalized().orthogonal()
	var amplitude := minf(ARC_MAX_JITTER, distance * 0.12)
	for point_index in range(ARC_POINT_COUNT):
		var progress := float(point_index) / float(ARC_POINT_COUNT - 1)
		var envelope := sin(progress * PI)
		var phase := float(
			(attack_action_id + 1) * 37
			+ (segment_index + 1) * 71
			+ point_index * 113
		)
		var jitter := (
			sin(phase * 0.173)
			+ cos(phase * 0.071) * 0.42
		) * amplitude * envelope
		result.append(start + span * progress + perpendicular * jitter)
	return result


func _play_release_animation(show_arcs: bool) -> void:
	_stop_charge_tween()
	_stop_flash_tween()
	arc_layer.visible = show_arcs
	arc_layer.modulate = Color.WHITE
	_set_release_flash(1.0)
	grape_night_light.set_emission_strength(RELEASE_LIGHT_STRENGTH)
	attack_animation_player.stop()
	attack_animation_player.play(&"release")
	flash_tween = create_tween()
	flash_tween.set_trans(Tween.TRANS_EXPO).set_ease(Tween.EASE_OUT)
	flash_tween.tween_method(_set_release_flash, 1.0, 0.0, 0.22)


func _on_attack_animation_finished(animation_name: StringName) -> void:
	if animation_name == &"release":
		_finish_attack_cycle()


func _finish_attack_cycle() -> void:
	release_timer.stop()
	_stop_charge_tween()
	_stop_flash_tween()
	attack_locked = false
	pending_primary_target = null
	_chain_targets.clear()
	grape_cluster_root.position = Vector2.ZERO
	grape_cluster_root.scale = Vector2.ONE
	firing_grape_root.position = Vector2.ZERO
	firing_grape_root.scale = Vector2.ONE
	_set_charge_progress(0.0)
	_set_release_flash(0.0)
	_hide_all_arcs()
	if is_operational and not is_removing:
		grape_night_light.set_emission_strength(IDLE_LIGHT_STRENGTH)
		_schedule_idle_scan(IDLE_SCAN_COOLDOWN_SECONDS)


func _reset_attack_visuals() -> void:
	grape_cluster_root.position = Vector2.ZERO
	grape_cluster_root.scale = Vector2.ONE
	firing_grape_root.position = Vector2.ZERO
	firing_grape_root.scale = Vector2.ONE
	_set_charge_progress(0.0)
	_set_release_flash(0.0)
	_reset_idle_scan_shader()
	_hide_all_arcs()


func _on_idle_scan_timer_timeout() -> void:
	if (
		not is_operational
		or is_dead
		or is_removing
		or attack_locked
	):
		return
	_begin_idle_scan()


func _begin_idle_scan() -> void:
	if (
		idle_scan_active
		or attack_locked
		or not is_operational
		or is_dead
		or is_removing
	):
		return
	idle_scan_timer.stop()
	_stop_idle_scan_tween()
	idle_scan_active = true
	_set_idle_scan_progress(0.0)
	_set_idle_scan_strength(1.0)
	idle_scan_tween = create_tween()
	idle_scan_tween.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
	idle_scan_tween.tween_method(
		_set_idle_scan_progress,
		0.0,
		1.0,
		IDLE_SCAN_TRAVEL_SECONDS
	)
	idle_scan_tween.set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
	idle_scan_tween.tween_method(
		_set_idle_scan_strength,
		1.0,
		0.0,
		IDLE_SCAN_FADE_SECONDS
	)
	idle_scan_tween.tween_callback(_finish_idle_scan)


func _finish_idle_scan() -> void:
	idle_scan_tween = null
	idle_scan_active = false
	_reset_idle_scan_shader()
	if is_operational and not is_dead and not is_removing and not attack_locked:
		_schedule_idle_scan(IDLE_SCAN_COOLDOWN_SECONDS)


func _schedule_idle_scan(delay_seconds: float) -> void:
	idle_scan_timer.stop()
	if (
		not is_operational
		or is_dead
		or is_removing
		or attack_locked
		or idle_scan_active
	):
		return
	idle_scan_timer.start(maxf(delay_seconds, 0.001))


func _cancel_idle_scan() -> void:
	idle_scan_timer.stop()
	_stop_idle_scan_tween()
	idle_scan_active = false
	_reset_idle_scan_shader()


func _set_idle_scan_progress(value: float) -> void:
	_idle_scan_progress = clampf(value, 0.0, 1.0)
	_apply_idle_scan_shader_parameters()


func _set_idle_scan_strength(value: float) -> void:
	_idle_scan_strength = clampf(value, 0.0, 1.0)
	_apply_idle_scan_shader_parameters()


func _apply_idle_scan_shader_parameters() -> void:
	var side_progress := clampf(_idle_scan_progress / 0.68, 0.0, 1.0)
	var firing_progress := clampf(
		(_idle_scan_progress - 0.30) / 0.70,
		0.0,
		1.0
	)
	var side_strength := (
		_idle_scan_strength
		* (1.0 - smoothstep(0.70, 1.0, _idle_scan_progress))
	)
	var firing_strength := (
		_idle_scan_strength
		* smoothstep(0.28, 0.36, _idle_scan_progress)
	)
	side_charge_overlay.set_instance_shader_parameter(
		&"idle_scan_progress",
		side_progress
	)
	side_charge_overlay.set_instance_shader_parameter(
		&"idle_scan_strength",
		side_strength
	)
	firing_charge_overlay.set_instance_shader_parameter(
		&"idle_scan_progress",
		firing_progress
	)
	firing_charge_overlay.set_instance_shader_parameter(
		&"idle_scan_strength",
		firing_strength
	)


func _reset_idle_scan_shader() -> void:
	_idle_scan_progress = 0.0
	_idle_scan_strength = 0.0
	_apply_idle_scan_shader_parameters()


func _set_charge_progress(value: float) -> void:
	var safe_value := clampf(value, 0.0, 1.0)
	var side_charge := clampf(safe_value / 0.64, 0.0, 1.0)
	var firing_charge := clampf((safe_value - 0.32) / 0.68, 0.0, 1.0)
	side_charge_overlay.set_instance_shader_parameter(
		&"charge_progress",
		side_charge
	)
	firing_charge_overlay.set_instance_shader_parameter(
		&"charge_progress",
		firing_charge
	)
	if is_operational and not is_removing:
		grape_night_light.set_emission_strength(lerpf(
			IDLE_LIGHT_STRENGTH,
			CHARGED_LIGHT_STRENGTH,
			safe_value
		))


func _set_release_flash(value: float) -> void:
	var safe_value := clampf(value, 0.0, 1.0)
	side_charge_overlay.set_instance_shader_parameter(
		&"release_flash",
		safe_value * 0.65
	)
	firing_charge_overlay.set_instance_shader_parameter(
		&"release_flash",
		safe_value
	)


func _hide_all_arcs() -> void:
	arc_layer.hide()
	for line in _arc_glows:
		line.hide()
	for line in _arc_cores:
		line.hide()


func _stop_charge_tween() -> void:
	if charge_tween != null and charge_tween.is_valid():
		charge_tween.kill()
	charge_tween = null


func _stop_flash_tween() -> void:
	if flash_tween != null and flash_tween.is_valid():
		flash_tween.kill()
	flash_tween = null


func _stop_idle_scan_tween() -> void:
	if idle_scan_tween != null and idle_scan_tween.is_valid():
		idle_scan_tween.kill()
	idle_scan_tween = null
