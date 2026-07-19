extends PlantDefense
class_name BambooMortar

const SHELL_SCENE := preload(
	"res://scene/plant_defense/bamboo_mortar_shell.tscn"
)
const AUDIO_LIMITER := preload(
	"res://scene/plant_defense/plant_attack_audio_limiter.gd"
)
const DEFAULT_ATTACK_DAMAGE := 100
const OUTER_ATTACK_DAMAGE := 50
const DEFAULT_ATTACK_RANGE := 160.0
const MINIMUM_ATTACK_RANGE := 64.0
const TARGET_RETRY_INTERVAL_SECONDS := 2.0
const WINDUP_DURATION_SECONDS := 4.0
const TARGET_TRACK_INTERVAL_SECONDS := 0.5
const WINDUP_FRAME_COUNT := 8
const WINDUP_FPS := 2.0
const FIRE_FRAME_COUNT := 4
const FIRE_FPS := 12.0
const FIRE_LAUNCH_FRAME := 1
const FIRE_DURATION_SECONDS := FIRE_FRAME_COUNT / FIRE_FPS
const FIRE_LAUNCH_LEAD_SECONDS := FIRE_LAUNCH_FRAME / FIRE_FPS
const RUNTIME_STATE_SCHEMA := 1
const NETWORK_STAGE_WINDUP := 0
const NETWORK_STAGE_FIRE := 1
const IDLE_GLOW_COLOR := Color(0.34, 1.65, 0.18, 1.0)
const CHARGE_GLOW_COLOR := Color(2.25, 0.62, 0.10, 1.0)
const MAIN_SPRITE_REST_POSITION := Vector2.ZERO
const FIRE_RECOIL_OFFSET := Vector2(-1.0, 1.0)

enum CombatPhase {
	IDLE,
	WINDUP,
	COOLDOWN,
	FIRING,
}

@onready var main_sprite: AnimatedSprite2D = $VisualRoot/MainSprite
@onready var status_light: Polygon2D = $VisualRoot/StatusLight
@onready var muzzle: Marker2D = $VisualRoot/Muzzle
@onready var attack_timer: Timer = $AttackTimer
@onready var target_track_timer: Timer = $TargetTrackTimer
@onready var health_bar: Control = $HealthBar
@onready var fire_audio: AudioStreamPlayer2D = $FireAudio

var configured_attack_damage := DEFAULT_ATTACK_DAMAGE
var configured_attack_range := DEFAULT_ATTACK_RANGE
var combat_phase := CombatPhase.IDLE
var pending_target: Enemy = null
var last_valid_target_position := Vector2.ZERO
var next_authoritative_action_id := 0
var latest_proxy_action_id := 0
var latest_proxy_stage := -1
var completed_authoritative_launch_count := 0

var _combat_runtime: Node = null
var _target_candidates: Array[Enemy] = []
var _target_request_pending := false
var _windup_started_at_seconds := 0.0
var _authoritative_fire_action_id := 0
var _latest_proxy_shell_action_id := 0
var _last_projectile_action_id := 0
var _last_projectile_started_at_seconds := -INF
var _last_projectile_spawn_position := Vector2.ZERO
var _last_projectile_landing_position := Vector2.ZERO


func _ready() -> void:
	super._ready()
	set_process(false)


func _on_setup_completed() -> void:
	super._on_setup_completed()
	_combat_runtime = get_tree().current_scene
	configured_attack_damage = maxi(config.attack_damage, 0)
	configured_attack_range = maxf(config.attack_range, 0.0)
	health_bar.call("setup", max_health, current_health)
	if not health_changed.is_connected(_on_health_changed):
		health_changed.connect(_on_health_changed)
	main_sprite.play(&"idle")
	main_sprite.position = MAIN_SPRITE_REST_POSITION
	_set_glow_state(false, 0)


func _on_construction_started() -> void:
	status_light.visible = false


func _on_construction_finished(_was_animated: bool) -> void:
	status_light.visible = true


func _on_operational_started() -> void:
	if is_multiplayer_proxy:
		_disable_proxy_combat_runtime()
		return
	_try_begin_windup()


func _on_multiplayer_proxy_configured() -> void:
	_disable_proxy_combat_runtime()


func _disable_proxy_combat_runtime() -> void:
	attack_timer.stop()
	target_track_timer.stop()
	_cancel_scheduled_target_request()
	pending_target = null
	_target_candidates.clear()
	combat_phase = CombatPhase.IDLE
	main_sprite.position = MAIN_SPRITE_REST_POSITION


func _on_removal_started(_mode: RemovalMode) -> void:
	attack_timer.stop()
	target_track_timer.stop()
	_cancel_scheduled_target_request()
	pending_target = null
	_target_candidates.clear()
	main_sprite.stop()
	main_sprite.position = MAIN_SPRITE_REST_POSITION
	status_light.visible = false
	fire_audio.stop()
	health_bar.hide()


func _on_health_changed(new_health: int, new_max_health: int) -> void:
	health_bar.call("set_health", new_health, new_max_health)


func _on_attack_timer_timeout() -> void:
	if is_multiplayer_proxy or is_dead or is_removing:
		return
	_try_begin_windup()


func _try_begin_windup() -> void:
	if (
		is_multiplayer_proxy
		or is_dead
		or is_removing
		or combat_phase == CombatPhase.WINDUP
		or combat_phase == CombatPhase.FIRING
		or _target_request_pending
	):
		return
	if (
		_combat_runtime != null
		and is_instance_valid(_combat_runtime)
		and _combat_runtime.has_method(
			"request_bamboo_mortar_target"
		)
	):
		_target_request_pending = true
		attack_timer.stop()
		var accepted := bool(
			_combat_runtime.call(
				"request_bamboo_mortar_target",
				self,
				MINIMUM_ATTACK_RANGE,
				configured_attack_range,
				Callable(
					self,
					"_on_bamboo_mortar_target_resolved"
				)
			)
		)
		if accepted:
			return
		_target_request_pending = false
	var target := _select_nearest_target_in_ring()
	if target == null:
		combat_phase = CombatPhase.IDLE
		attack_timer.start(TARGET_RETRY_INTERVAL_SECONDS)
		return
	_begin_authoritative_windup(target)


func _on_bamboo_mortar_target_resolved(target: Variant) -> void:
	if not _target_request_pending:
		return
	_target_request_pending = false
	if (
		is_multiplayer_proxy
		or is_dead
		or is_removing
		or combat_phase == CombatPhase.WINDUP
		or combat_phase == CombatPhase.FIRING
	):
		return
	if not _is_valid_target(target):
		combat_phase = CombatPhase.IDLE
		attack_timer.start(TARGET_RETRY_INTERVAL_SECONDS)
		return
	_begin_authoritative_windup(target as Enemy)


func _cancel_scheduled_target_request() -> void:
	if not _target_request_pending:
		return
	_target_request_pending = false
	if (
		_combat_runtime == null
		or not is_instance_valid(_combat_runtime)
		or not _combat_runtime.has_method(
			"cancel_bamboo_mortar_target_request"
		)
	):
		return
	_combat_runtime.call(
		"cancel_bamboo_mortar_target_request",
		self
	)


func _begin_authoritative_windup(target: Enemy) -> void:
	_target_request_pending = false
	pending_target = target
	last_valid_target_position = target.global_position
	next_authoritative_action_id += 1
	combat_phase = CombatPhase.WINDUP
	_authoritative_fire_action_id = 0
	_windup_started_at_seconds = _now_seconds()
	attack_timer.stop()
	target_track_timer.start(TARGET_TRACK_INTERVAL_SECONDS)
	main_sprite.position = MAIN_SPRITE_REST_POSITION
	main_sprite.play(&"charge")
	main_sprite.set_frame_and_progress(0, 0.0)
	_set_glow_state(true, 0)
	_queue_network_visual(
		NETWORK_STAGE_WINDUP,
		next_authoritative_action_id,
		muzzle.global_position,
		last_valid_target_position
	)


func _on_target_track_timer_timeout() -> void:
	if combat_phase != CombatPhase.WINDUP or is_multiplayer_proxy:
		target_track_timer.stop()
		return
	_update_last_valid_target_position()


func _update_last_valid_target_position() -> void:
	var tracked_target: Variant = pending_target
	if not _is_valid_target(tracked_target):
		pending_target = null
		return
	var valid_target := tracked_target as Enemy
	var distance_squared := global_position.distance_squared_to(
		valid_target.global_position
	)
	if (
		distance_squared <= configured_attack_range * configured_attack_range
		and distance_squared
		> MINIMUM_ATTACK_RANGE * MINIMUM_ATTACK_RANGE
	):
		last_valid_target_position = valid_target.global_position


func _on_main_sprite_frame_changed() -> void:
	if main_sprite.animation == &"charge":
		_set_glow_state(true, main_sprite.frame)
		return
	if main_sprite.animation != &"fire":
		return
	_set_glow_state(true, WINDUP_FRAME_COUNT - 1)
	_set_fire_recoil_for_frame(main_sprite.frame)
	if (
		main_sprite.frame == FIRE_LAUNCH_FRAME
		and not is_multiplayer_proxy
		and _authoritative_fire_action_id
		!= next_authoritative_action_id
	):
		_fire_authoritative_shell()


func _on_main_sprite_animation_finished() -> void:
	if main_sprite.animation == &"charge":
		if combat_phase != CombatPhase.WINDUP:
			return
		if is_multiplayer_proxy:
			# The authoritative launch event is emitted on fire frame 1. Let
			# proxies locally show frame 0 when their synchronized charge ends,
			# then let the event correct them to the projectile timeline.
			combat_phase = CombatPhase.FIRING
			main_sprite.position = MAIN_SPRITE_REST_POSITION
			main_sprite.play(&"fire")
			main_sprite.set_frame_and_progress(0, 0.0)
			_set_glow_state(true, WINDUP_FRAME_COUNT - 1)
			return
		_begin_authoritative_fire_animation()
		return
	if main_sprite.animation != &"fire":
		return
	if (
		not is_multiplayer_proxy
		and _authoritative_fire_action_id
		!= next_authoritative_action_id
		and not is_dead
		and not is_removing
	):
		_fire_authoritative_shell()
	_finish_fire_visual()


func _begin_authoritative_fire_animation() -> void:
	if (
		is_multiplayer_proxy
		or is_dead
		or is_removing
		or combat_phase != CombatPhase.WINDUP
	):
		return
	main_sprite.position = MAIN_SPRITE_REST_POSITION
	main_sprite.play(&"fire")
	main_sprite.set_frame_and_progress(0, 0.0)
	_set_glow_state(true, WINDUP_FRAME_COUNT - 1)


func _fire_authoritative_shell() -> void:
	if (
		is_multiplayer_proxy
		or is_dead
		or is_removing
		or _authoritative_fire_action_id
		== next_authoritative_action_id
	):
		return
	_authoritative_fire_action_id = next_authoritative_action_id
	combat_phase = CombatPhase.FIRING
	_update_last_valid_target_position()
	target_track_timer.stop()
	if main_sprite.animation != &"fire":
		main_sprite.play(&"fire")
		main_sprite.set_frame_and_progress(
			FIRE_LAUNCH_FRAME,
			0.0
		)
	_set_fire_recoil_for_frame(FIRE_LAUNCH_FRAME)
	_set_glow_state(true, WINDUP_FRAME_COUNT - 1)
	var action_id := next_authoritative_action_id
	var spawn_position := muzzle.global_position
	var landing_position := last_valid_target_position
	_last_projectile_action_id = action_id
	_last_projectile_started_at_seconds = _now_seconds()
	_last_projectile_spawn_position = spawn_position
	_last_projectile_landing_position = landing_position
	_spawn_shell(
		spawn_position,
		landing_position,
		true,
		0.0
	)
	AUDIO_LIMITER.play_burst(fire_audio)
	completed_authoritative_launch_count += 1
	_queue_network_visual(
		NETWORK_STAGE_FIRE,
		action_id,
		spawn_position,
		landing_position
	)
	pending_target = null


func _finish_fire_visual() -> void:
	main_sprite.position = MAIN_SPRITE_REST_POSITION
	main_sprite.play(&"idle")
	_set_glow_state(false, 0)
	if combat_phase != CombatPhase.FIRING:
		return
	if is_multiplayer_proxy:
		combat_phase = CombatPhase.COOLDOWN
		return
	combat_phase = CombatPhase.IDLE
	call_deferred("_try_begin_windup")


func _set_fire_recoil_for_frame(frame_index: int) -> void:
	main_sprite.position = (
		FIRE_RECOIL_OFFSET
		if frame_index == 1 or frame_index == 2
		else MAIN_SPRITE_REST_POSITION
	)


func get_completed_authoritative_launch_count() -> int:
	return completed_authoritative_launch_count


func _spawn_shell(
	spawn_position: Vector2,
	landing_position: Vector2,
	can_apply_damage: bool,
	initial_elapsed_seconds: float
) -> BambooMortarShell:
	if (
		initial_elapsed_seconds
		>= BambooMortarShell.get_total_visual_duration_seconds(
			spawn_position,
			landing_position
		)
	):
		return null
	var spawn_parent := get_tree().current_scene
	if spawn_parent == null:
		return null
	var shell: BambooMortarShell = null
	if (
		spawn_parent.has_method("has_session_object_pool_scene")
		and bool(
			spawn_parent.call(
				"has_session_object_pool_scene",
				SHELL_SCENE
			)
		)
	):
		shell = spawn_parent.call(
			"acquire_session_object",
			SHELL_SCENE,
			false
		) as BambooMortarShell
	else:
		shell = SHELL_SCENE.instantiate() as BambooMortarShell
	if shell == null:
		return null
	shell.top_level = true
	if shell.get_parent() == null:
		spawn_parent.add_child(shell)
	shell.setup(
		spawn_position,
		landing_position,
		configured_attack_damage,
		OUTER_ATTACK_DAMAGE,
		can_apply_damage,
		int(get_meta(&"net_id", get_instance_id())),
		initial_elapsed_seconds
	)
	shell.reset_physics_interpolation()
	return shell


func _select_nearest_target_in_ring() -> Enemy:
	_target_candidates.clear()
	if (
		_combat_runtime == null
		or not is_instance_valid(_combat_runtime)
		or not _combat_runtime.has_method(
			"query_combat_targets_unordered_into"
		)
	):
		return null
	_combat_runtime.call(
		"query_combat_targets_unordered_into",
		global_position,
		configured_attack_range,
		_target_candidates
	)
	var minimum_distance_squared := (
		MINIMUM_ATTACK_RANGE * MINIMUM_ATTACK_RANGE
	)
	var maximum_distance_squared := (
		configured_attack_range * configured_attack_range
	)
	var nearest: Enemy = null
	var nearest_distance_squared := INF
	var nearest_instance_id := 0
	for candidate in _target_candidates:
		if not _is_valid_target(candidate):
			continue
		var distance_squared := global_position.distance_squared_to(
			candidate.global_position
		)
		if (
			distance_squared <= minimum_distance_squared
			or distance_squared > maximum_distance_squared
		):
			continue
		var candidate_instance_id := candidate.get_instance_id()
		if (
			distance_squared < nearest_distance_squared
			or (
				is_equal_approx(
					distance_squared,
					nearest_distance_squared
				)
				and (
					nearest == null
					or candidate_instance_id < nearest_instance_id
				)
			)
		):
			nearest = candidate
			nearest_distance_squared = distance_squared
			nearest_instance_id = candidate_instance_id
	return nearest


func _is_valid_target(enemy: Variant) -> bool:
	if enemy == null or not is_instance_valid(enemy):
		return false
	var valid_enemy := enemy as Enemy
	return (
		valid_enemy != null
		and valid_enemy.is_inside_tree()
		and not valid_enemy.is_dead
	)


func _queue_network_visual(
	stage: int,
	action_id: int,
	spawn_position: Vector2,
	landing_position: Vector2
) -> void:
	if (
		_combat_runtime == null
		or not _combat_runtime.has_method(
			"queue_bamboo_mortar_visual"
		)
	):
		return
	_combat_runtime.call(
		"queue_bamboo_mortar_visual",
		int(get_meta(&"net_id", 0)),
		action_id,
		stage,
		spawn_position,
		landing_position
	)


func play_multiplayer_action(
	stage: int,
	action_id: int,
	spawn_position: Vector2,
	landing_position: Vector2,
	elapsed_seconds: float
) -> void:
	if (
		not is_multiplayer_proxy
		or is_dead
		or is_removing
		or action_id <= 0
		or stage < NETWORK_STAGE_WINDUP
		or stage > NETWORK_STAGE_FIRE
		or not spawn_position.is_finite()
		or not landing_position.is_finite()
		or not is_finite(elapsed_seconds)
	):
		return
	if action_id < latest_proxy_action_id:
		return
	if action_id == latest_proxy_action_id and stage <= latest_proxy_stage:
		return
	if action_id > latest_proxy_action_id:
		latest_proxy_action_id = action_id
		latest_proxy_stage = -1
	latest_proxy_stage = stage
	if stage == NETWORK_STAGE_WINDUP:
		_play_proxy_windup(elapsed_seconds)
		return
	_play_proxy_fire(elapsed_seconds)
	AUDIO_LIMITER.play_burst(fire_audio, elapsed_seconds)
	_spawn_proxy_shell_once(
		action_id,
		spawn_position,
		landing_position,
		elapsed_seconds
	)


func _play_proxy_windup(elapsed_seconds: float) -> void:
	var safe_elapsed := clampf(
		elapsed_seconds,
		0.0,
		WINDUP_DURATION_SECONDS
	)
	var frame_position := safe_elapsed * WINDUP_FPS
	var frame_index := clampi(
		floori(frame_position),
		0,
		WINDUP_FRAME_COUNT - 1
	)
	combat_phase = CombatPhase.WINDUP
	main_sprite.position = MAIN_SPRITE_REST_POSITION
	main_sprite.play(&"charge")
	main_sprite.set_frame_and_progress(
		frame_index,
		clampf(frame_position - float(frame_index), 0.0, 0.999)
	)
	_set_glow_state(true, frame_index)


func _play_proxy_fire(projectile_elapsed_seconds: float) -> void:
	var fire_elapsed := (
		maxf(projectile_elapsed_seconds, 0.0)
		+ FIRE_LAUNCH_LEAD_SECONDS
	)
	if fire_elapsed >= FIRE_DURATION_SECONDS:
		main_sprite.position = MAIN_SPRITE_REST_POSITION
		main_sprite.play(&"idle")
		_set_glow_state(false, 0)
		combat_phase = CombatPhase.COOLDOWN
		return
	var frame_position := fire_elapsed * FIRE_FPS
	var frame_index := clampi(
		floori(frame_position),
		0,
		FIRE_FRAME_COUNT - 1
	)
	combat_phase = CombatPhase.FIRING
	main_sprite.play(&"fire")
	main_sprite.set_frame_and_progress(
		frame_index,
		clampf(frame_position - float(frame_index), 0.0, 0.999)
	)
	_set_glow_state(true, WINDUP_FRAME_COUNT - 1)
	_set_fire_recoil_for_frame(frame_index)


func _spawn_proxy_shell_once(
	action_id: int,
	spawn_position: Vector2,
	landing_position: Vector2,
	elapsed_seconds: float
) -> void:
	if action_id <= _latest_proxy_shell_action_id:
		return
	_latest_proxy_shell_action_id = action_id
	_spawn_shell(
		spawn_position,
		landing_position,
		false,
		maxf(elapsed_seconds, 0.0)
	)


func export_multiplayer_runtime_state() -> Dictionary:
	var now := _now_seconds()
	var state := {
		"schema": RUNTIME_STATE_SCHEMA,
		"combat_phase": int(combat_phase),
		"action_id": next_authoritative_action_id,
	}
	if combat_phase == CombatPhase.WINDUP:
		state["windup_elapsed_seconds"] = clampf(
			now - _windup_started_at_seconds,
			0.0,
			WINDUP_DURATION_SECONDS
		)
		state["windup_target_position"] = last_valid_target_position
	var projectile_elapsed := now - _last_projectile_started_at_seconds
	if (
		_last_projectile_action_id > 0
		and projectile_elapsed >= 0.0
		and projectile_elapsed
		< BambooMortarShell.get_total_visual_duration_seconds(
			_last_projectile_spawn_position,
			_last_projectile_landing_position
		)
	):
		state["projectile_action_id"] = _last_projectile_action_id
		state["projectile_elapsed_seconds"] = projectile_elapsed
		state["projectile_spawn_position"] = (
			_last_projectile_spawn_position
		)
		state["projectile_landing_position"] = (
			_last_projectile_landing_position
		)
	return state


func apply_multiplayer_runtime_state(
	state: Dictionary,
	_mapped_sample_time: float
) -> void:
	if (
		not is_multiplayer_proxy
		or int(state.get("schema", 0)) != RUNTIME_STATE_SCHEMA
	):
		return
	var action_id := maxi(int(state.get("action_id", 0)), 0)
	var phase := clampi(
		int(state.get("combat_phase", CombatPhase.IDLE)),
		CombatPhase.IDLE,
		CombatPhase.FIRING
	)
	if phase == CombatPhase.WINDUP and action_id > 0:
		var target_position := state.get(
			"windup_target_position",
			global_position
		) as Vector2
		play_multiplayer_action(
			NETWORK_STAGE_WINDUP,
			action_id,
			muzzle.global_position,
			target_position,
			maxf(
				float(
					state.get(
						"windup_elapsed_seconds",
						0.0
					)
				),
				0.0
			)
		)
	var projectile_action_id := maxi(
		int(state.get("projectile_action_id", 0)),
		0
	)
	if projectile_action_id <= 0:
		if (
			phase != CombatPhase.WINDUP
			and (
				action_id > latest_proxy_action_id
				or (
					action_id == latest_proxy_action_id
					and latest_proxy_stage < NETWORK_STAGE_FIRE
				)
			)
		):
			latest_proxy_action_id = action_id
			latest_proxy_stage = NETWORK_STAGE_FIRE
			combat_phase = phase
			main_sprite.position = MAIN_SPRITE_REST_POSITION
			main_sprite.play(&"idle")
			_set_glow_state(false, 0)
		return
	var spawn_position := state.get(
		"projectile_spawn_position",
		muzzle.global_position
	) as Vector2
	var landing_position := state.get(
		"projectile_landing_position",
		global_position
	) as Vector2
	var projectile_elapsed := maxf(
		float(state.get("projectile_elapsed_seconds", 0.0)),
		0.0
	)
	if (
		spawn_position.is_finite()
		and landing_position.is_finite()
		and is_finite(projectile_elapsed)
	):
		play_multiplayer_action(
			NETWORK_STAGE_FIRE,
			projectile_action_id,
			spawn_position,
			landing_position,
			projectile_elapsed
		)


func _set_glow_state(charging: bool, frame_index: int) -> void:
	var safe_frame := clampi(frame_index, 0, WINDUP_FRAME_COUNT - 1)
	status_light.set_instance_shader_parameter(
		&"glow_color",
		CHARGE_GLOW_COLOR if charging else IDLE_GLOW_COLOR
	)
	status_light.set_instance_shader_parameter(
		&"glow_strength",
		(
			1.0 + 0.55 * float(safe_frame)
			/ float(WINDUP_FRAME_COUNT - 1)
			if charging
			else 1.0
		)
	)


func _now_seconds() -> float:
	return Time.get_ticks_msec() / 1000.0
