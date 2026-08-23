extends "res://scene/enemy/capoo_ranged_enemy.gd"
class_name FireSorcerer

const FireConfig := preload(
	"res://resources/config/enemies/fire_sorcerer_config.gd"
)
const ENEMY_ATTACK_AUDIO_LIMITER := preload(
	"res://scene/combat/audio/enemy_attack_audio_limiter.gd"
)
const ATTACK_TARGET_REFRESH_INTERVAL := 0.35
const ATTACK_TARGET_QUERY_METHOD := &"find_nearest_enemy_attack_target_world"
const NORMAL_PROJECTILE_SOURCE_TYPE := &"fire_sorcerer_fireball_volley"
const ELITE_PROJECTILE_SOURCE_TYPE := &"fire_sorcerer_elite_fireball_volley"

enum ProjectileBackend {
	LEGACY,
	SHADOW,
	DATA,
}

# The three-ball kernel keeps every authored ball independent and preserves the
# original one-physics-tick activation boundary. Production authority is DATA;
# this explicit process-wide switch remains available for parity probes.
static var projectile_backend: ProjectileBackend = ProjectileBackend.DATA

enum CombatState {
	CHASE,
	SUMMON,
}

@export_group("投射物身份")
@export var projectile_source_type: StringName = (
	NORMAL_PROJECTILE_SOURCE_TYPE
)

@onready var summon_pivot: Node2D = $SummonPivot
@onready var summon_markers: Array[Marker2D] = [
	$SummonPivot/SpawnA,
	$SummonPivot/SpawnB,
	$SummonPivot/SpawnC,
]
@onready var summon_previews: Array[AnimatedSprite2D] = [
	$SummonPivot/FireballPreviewA,
	$SummonPivot/FireballPreviewB,
	$SummonPivot/FireballPreviewC,
]
@onready var summon_animation_player: AnimationPlayer = $SummonAnimationPlayer
@onready var attack_audio: AudioStreamPlayer2D = $AttackAudio

var combat_state: CombatState = CombatState.CHASE
var attack_cooldown_left: float = 0.0
var initial_attack_stagger_left: float = 0.0
var summon_time_left: float = 0.0
var summon_direction := Vector2.RIGHT
var summon_target: Node2D = null
var latest_proxy_action_id: int = 0
var cached_runtime_attack_target: Node2D = null
var attack_target_refresh_left: float = 0.0
var shadow_registration_failures: int = 0


func _ready() -> void:
	super._ready()
	_hide_summon_previews()


func _get_touch_damage_type() -> EnemyConfig.DamageType:
	return EnemyConfig.DamageType.MAGIC


func _select_nearest_attack_target(
	fallback_target: Node2D,
	fire_config: FireConfig,
	allow_runtime_refresh: bool
) -> Node2D:
	if not _is_ranged_combat_target_valid(cached_runtime_attack_target):
		cached_runtime_attack_target = null
		attack_target_refresh_left = 0.0
	if allow_runtime_refresh and attack_target_refresh_left <= 0.0:
		attack_target_refresh_left = ATTACK_TARGET_REFRESH_INTERVAL
		if combat_runtime != null and is_instance_valid(combat_runtime):
			cached_runtime_attack_target = (
				combat_runtime.find_nearest_enemy_attack_target_world(
					global_position,
					fire_config.attack_range
				)
			)
			if not _is_ranged_combat_target_valid(
				cached_runtime_attack_target
			):
				cached_runtime_attack_target = null
	if cached_runtime_attack_target == null:
		return fallback_target
	if not _is_ranged_combat_target_valid(fallback_target):
		return cached_runtime_attack_target
	var cached_distance_squared := global_position.distance_squared_to(
		cached_runtime_attack_target.global_position
	)
	var fallback_distance_squared := global_position.distance_squared_to(
		fallback_target.global_position
	)
	if (
		cached_distance_squared < fallback_distance_squared
		and not is_equal_approx(
			cached_distance_squared,
			fallback_distance_squared
		)
	):
		return cached_runtime_attack_target
	if (
		is_equal_approx(
			cached_distance_squared,
			fallback_distance_squared
		)
		and cached_runtime_attack_target.get_instance_id()
			< fallback_target.get_instance_id()
	):
		return cached_runtime_attack_target
	return fallback_target


func _physics_process(delta: float) -> void:
	if is_dead:
		velocity = Vector2.ZERO
		return

	_update_touch_damage(delta)
	_update_attack_cooldown(delta)
	if combat_state == CombatState.SUMMON:
		_update_summon(delta)
		return

	var fire_config := config as FireConfig
	var combat_target := get_resolved_combat_target()
	if combat_target == null and fire_config != null:
		var family_target := _select_nearest_attack_target(
			_get_family_proactive_ranged_combat_target(),
			fire_config,
			initial_attack_stagger_left <= 0.0
				and attack_cooldown_left <= 0.0
		)
		combat_target = get_resolved_combat_target(family_target)
	if (
		combat_target != null
		and fire_config != null
		and (
			FireSorcerer.projectile_backend != ProjectileBackend.LEGACY
			or fire_config.volley_scene != null
		)
		and _try_hold_ranged_attack_position(
			combat_target,
			fire_config.attack_range,
			WORLD_COLLISION_MASK
		)
	):
		if (
			initial_attack_stagger_left <= 0.0
			and _try_start_summon(combat_target, fire_config)
		):
			return
		# 精确攻击提交可能否定先前缓存的无遮挡结果；同一物理帧再确认一次，
		# 避免障碍刚出现时仍停在原地。
		if _try_hold_ranged_attack_position(
			combat_target,
			fire_config.attack_range,
			WORLD_COLLISION_MASK
		):
			velocity = Vector2.ZERO
			_update_facing(global_position.direction_to(combat_target.global_position))
			return
	else:
		_reset_ranged_attack_position_state()

	if not is_instance_valid(objective_target):
		velocity = Vector2.ZERO
		_move_until_player_contact()
		return

	if _has_player_contact():
		velocity = Vector2.ZERO
		return

	var move_direction := _get_navigation_move_direction(delta)
	_update_facing(move_direction)
	velocity = move_direction * _get_move_speed()
	_move_until_player_contact()


func _apply_config() -> void:
	super._apply_config()
	combat_state = CombatState.CHASE
	attack_cooldown_left = 0.0
	var fire_config := config as FireConfig
	initial_attack_stagger_left = (
		_get_deterministic_initial_stagger(
			fire_config.initial_attack_stagger_window
		)
		if fire_config != null
		else 0.0
	)
	summon_time_left = 0.0
	summon_direction = Vector2.RIGHT
	summon_target = null
	latest_proxy_action_id = 0
	cached_runtime_attack_target = null
	attack_target_refresh_left = 0.0
	shadow_registration_failures = 0
	_reset_ranged_attack_position_state()
	if is_node_ready():
		_hide_summon_previews()
		if fire_config != null:
			attack_audio.stream = fire_config.attack_audio_stream


func _die() -> void:
	_cancel_summon(false)
	super._die()


func play_multiplayer_death_sequence() -> void:
	latest_proxy_action_id += 1
	_hide_summon_previews()
	super.play_multiplayer_death_sequence()


func _update_attack_cooldown(delta: float) -> void:
	if initial_attack_stagger_left > 0.0:
		initial_attack_stagger_left = maxf(
			initial_attack_stagger_left - delta,
			0.0
		)
	if attack_cooldown_left > 0.0:
		attack_cooldown_left = maxf(attack_cooldown_left - delta, 0.0)
	if attack_target_refresh_left > 0.0:
		attack_target_refresh_left = maxf(
			attack_target_refresh_left - delta,
			0.0
		)


func _try_start_summon(
	attack_target: Node2D,
	fire_config: FireConfig
) -> bool:
	if attack_cooldown_left > 0.0:
		return false
	var priority_target := get_resolved_combat_target()
	if priority_target != null:
		attack_target = priority_target
	else:
		attack_target = get_resolved_combat_target(
			_select_nearest_attack_target(
				attack_target,
				fire_config,
				true
			)
		)
	if not _is_ranged_combat_target_in_range(
		attack_target,
		fire_config.attack_range
	):
		return false
	if not _has_ranged_combat_line(
		attack_target,
		WORLD_COLLISION_MASK,
		true
	):
		return false

	combat_state = CombatState.SUMMON
	summon_target = attack_target
	summon_time_left = maxf(fire_config.summon_duration, 0.01)
	summon_direction = global_position.direction_to(attack_target.global_position)
	if summon_direction == Vector2.ZERO:
		summon_direction = Vector2.RIGHT
	velocity = Vector2.ZERO
	_set_ranged_attack_position_held(true)
	_update_facing(summon_direction)
	_play_config_animation(fire_config.windup_animation_name)
	_start_summon_preview(fire_config.summon_duration, summon_direction)
	_broadcast_enemy_action(&"summon", summon_direction)
	return true


func _update_summon(delta: float) -> void:
	var fire_config := config as FireConfig
	if (
		fire_config == null
		or not _is_ranged_combat_target_valid(summon_target)
	):
		_cancel_summon()
		return
	if not _is_ranged_combat_target_in_range(
		summon_target,
		fire_config.attack_range
	):
		_cancel_summon()
		return

	velocity = Vector2.ZERO
	summon_direction = global_position.direction_to(summon_target.global_position)
	if summon_direction == Vector2.ZERO:
		summon_direction = Vector2.RIGHT
	summon_pivot.rotation = summon_direction.angle()
	_update_facing(summon_direction)
	summon_time_left = maxf(summon_time_left - delta, 0.0)
	if summon_time_left > 0.0:
		return
	if not _has_ranged_combat_line(
		summon_target,
		WORLD_COLLISION_MASK,
		true
	):
		_cancel_summon()
		return
	_finish_summon_and_fire(fire_config)


func _finish_summon_and_fire(fire_config: FireConfig) -> void:
	_hide_summon_previews()
	_play_config_animation(fire_config.attack_animation_name)
	var fired := _spawn_fireball_volley(fire_config)
	# 冷却从生成阶段完成这一刻起算。即使极端池分配失败，也保持节流，
	# 避免同一物理帧反复尝试创建对象。
	attack_cooldown_left = maxf(fire_config.attack_interval, 0.01)
	_broadcast_enemy_action(&"fire", summon_direction)
	if fired and fire_config.attack_audio_stream != null:
		attack_audio.pitch_scale = random_generator.randf_range(0.95, 1.05)
		ENEMY_ATTACK_AUDIO_LIMITER.play_heavy_attack(attack_audio)
	combat_state = CombatState.CHASE
	summon_time_left = 0.0
	summon_target = null


func _on_animated_sprite_animation_finished() -> void:
	super._on_animated_sprite_animation_finished()
	var fire_config := config as FireConfig
	if (
		is_dead
		or combat_state != CombatState.CHASE
		or fire_config == null
		or animated_sprite.animation != fire_config.attack_animation_name
	):
		return
	_play_config_animation(fire_config.move_animation_name)


func _spawn_fireball_volley(fire_config: FireConfig) -> bool:
	if (
		combat_runtime == null
		or not is_instance_valid(combat_runtime)
	):
		return false
	# Client enemies only replay the Host action. The projectile coordinator
	# rebuilds visual-only REPLICA rows from the Host registration.
	if combat_runtime.runtime_mode == CombatRuntimeBase.RuntimeMode.CLIENT_VIEW:
		return false
	match FireSorcerer.projectile_backend:
		ProjectileBackend.LEGACY:
			return _spawn_legacy_fireball_volley(fire_config, false)
		ProjectileBackend.SHADOW:
			return _spawn_legacy_fireball_volley(fire_config, true)
		ProjectileBackend.DATA:
			return _spawn_data_fireball_volley(fire_config)
	return false


func _spawn_legacy_fireball_volley(
	fire_config: FireConfig,
	register_shadow: bool
) -> bool:
	if (
		fire_config.volley_scene == null
		or gameplay_gateway == null
		or not is_instance_valid(gameplay_gateway)
	):
		return false
	var fire_sorcerer_service: FireSorcererVolleySimulationService = null
	if register_shadow:
		fire_sorcerer_service = (
			_get_fire_sorcerer_volley_simulation_service()
		)
	var spawn_parent: Node = combat_runtime
	var volley: FireSorcererFireballVolley = null
	if combat_runtime.has_session_object_pool_scene(fire_config.volley_scene):
		volley = combat_runtime.acquire_session_object(
			fire_config.volley_scene,
			false
		) as FireSorcererFireballVolley
	else:
		volley = (
			fire_config.volley_scene.instantiate()
			as FireSorcererFireballVolley
		)
	if volley == null:
		push_warning("火焰术士齐射场景必须实例化 FireSorcererFireballVolley。")
		return false

	var outgoing_damage := get_effective_attack_damage(fire_config.attack_damage)
	volley.bind_gameplay_context(combat_runtime, gameplay_gateway)
	volley.top_level = true
	volley.setup(
		summon_direction,
		outgoing_damage,
		fire_config.projectile_speed,
		fire_config.projectile_lifetime,
		summon_target,
		fire_config.homing_turn_rate,
		combat_runtime,
		fire_config.burn_duration,
		fire_config.burn_level,
		create_damage_source_snapshot(0, _get_fireball_projectile_type())
	)
	if volley.get_parent() == null:
		spawn_parent.add_child(volley)
	elif volley.get_parent() != spawn_parent:
		volley.reparent(spawn_parent)
	# 与场景中三枚预览火球共用法杖前方的旋转枢轴，避免完成前摇时
	# 实体火球相对预览图像向下跳动。
	volley.global_position = summon_pivot.global_position
	volley.reset_physics_interpolation()
	var target_peer_id := 0
	var target_plant_net_id := 0
	var player_target := summon_target as Player
	if player_target != null:
		target_peer_id = player_target.peer_id
	else:
		var plant_target := summon_target as PlantDefense
		if plant_target != null:
			target_plant_net_id = int(plant_target.get_meta(&"net_id", 0))
		else:
			var enemy_target := summon_target as Enemy
			if enemy_target != null:
				target_plant_net_id = int(enemy_target.get_meta(&"net_id", 0))
	gameplay_gateway.register_local_projectile(
		volley,
		_get_fireball_projectile_type(),
		0,
		volley.global_position,
		summon_direction,
		outgoing_damage,
		fire_config.projectile_speed,
		fire_config.projectile_lifetime,
		false,
		target_peer_id,
		target_plant_net_id
	)
	if register_shadow and fire_sorcerer_service != null:
		var shadow_handle := fire_sorcerer_service.register_volley(
			FireSorcererVolleySimulationService.Mode.SHADOW,
			_get_fire_sorcerer_volley_profile(),
			_get_authored_volley_positions(),
			_get_authored_volley_directions(),
			fire_config.projectile_speed,
			fire_config.projectile_lifetime,
			fire_config.homing_turn_rate,
			0,
			_get_stable_source_enemy_id(),
			0,
			summon_target,
			0.0,
			0,
			null
		)
		if shadow_handle <= FireSorcererVolleySimulationService.INVALID_HANDLE:
			shadow_registration_failures += 1
	elif register_shadow:
		# SHADOW is comparison-only. Missing infrastructure cannot replace or
		# cancel the already registered legacy authority volley.
		shadow_registration_failures += 1
	return true


func _spawn_data_fireball_volley(fire_config: FireConfig) -> bool:
	var fire_sorcerer_service := (
		_get_fire_sorcerer_volley_simulation_service()
	)
	if fire_sorcerer_service == null:
		return false
	var profile := _get_fire_sorcerer_volley_profile()
	if profile == FireSorcererVolleySimulationService.Profile.INVALID:
		return false
	var outgoing_damage := get_effective_attack_damage(
		fire_config.attack_damage
	)
	var launch_source_snapshot := create_damage_source_snapshot(
		0,
		_get_fireball_projectile_type()
	)
	var handle := fire_sorcerer_service.register_volley(
		FireSorcererVolleySimulationService.Mode.DATA,
		profile,
		_get_authored_volley_positions(),
		_get_authored_volley_directions(),
		fire_config.projectile_speed,
		fire_config.projectile_lifetime,
		fire_config.homing_turn_rate,
		outgoing_damage,
		_get_stable_source_enemy_id(),
		0,
		summon_target,
		fire_config.burn_duration,
		fire_config.burn_level,
		launch_source_snapshot
	)
	if handle <= FireSorcererVolleySimulationService.INVALID_HANDLE:
		return false

	if (
		combat_runtime.runtime_mode
		== CombatRuntimeBase.RuntimeMode.HOST_AUTHORITY
	):
		if gameplay_gateway == null or not is_instance_valid(gameplay_gateway):
			fire_sorcerer_service.release_volley(handle)
			return false
		var target_peer_id := 0
		var target_enemy_net_id := 0
		var player_target := summon_target as Player
		if player_target != null:
			target_peer_id = player_target.peer_id
		else:
			var plant_target := summon_target as PlantDefense
			if plant_target != null:
				target_enemy_net_id = int(
					plant_target.get_meta(&"net_id", 0)
				)
			else:
				var enemy_target := summon_target as Enemy
				if enemy_target != null:
					target_enemy_net_id = int(
						enemy_target.get_meta(&"net_id", 0)
					)
		var projectile_id := (
			gameplay_gateway.register_local_fire_sorcerer_volley_data(
				fire_sorcerer_service,
				handle,
				_get_fireball_projectile_type(),
				0,
				summon_pivot.global_position,
				summon_direction,
				outgoing_damage,
				fire_config.projectile_speed,
				fire_config.projectile_lifetime,
				target_peer_id,
				target_enemy_net_id,
				launch_source_snapshot
			)
		)
		if projectile_id <= 0:
			# Host identity registration and the pending service row are one
			# operation. Failure releases the row and never falls back to a Node.
			fire_sorcerer_service.release_volley(handle)
			return false
	return true


func _get_authored_volley_positions() -> PackedVector2Array:
	var positions := PackedVector2Array()
	positions.resize(FireSorcererVolleySimulationService.BALL_COUNT)
	for ball_index in range(FireSorcererVolleySimulationService.BALL_COUNT):
		positions[ball_index] = summon_markers[ball_index].global_position
	return positions


func _get_authored_volley_directions() -> PackedVector2Array:
	var safe_direction := (
		summon_direction.normalized()
		if summon_direction != Vector2.ZERO
		else Vector2.RIGHT
	)
	var directions := PackedVector2Array()
	directions.resize(FireSorcererVolleySimulationService.BALL_COUNT)
	directions.fill(safe_direction)
	return directions


func _get_fire_sorcerer_volley_profile(
) -> FireSorcererVolleySimulationService.Profile:
	return (
		FireSorcererVolleySimulationService.Profile.ELITE
		if projectile_source_type == ELITE_PROJECTILE_SOURCE_TYPE
		else FireSorcererVolleySimulationService.Profile.NORMAL
	)


func _get_fire_sorcerer_volley_simulation_service(
) -> FireSorcererVolleySimulationService:
	var combat_services := combat_runtime.get_enemy_combat_services()
	if combat_services == null:
		return null
	return combat_services.get_fire_sorcerer_volley_simulation_service()


func _get_stable_source_enemy_id() -> int:
	var network_enemy_id := int(get_meta(&"net_id", 0))
	if network_enemy_id > 0:
		return network_enemy_id
	return int(get_instance_id())


func _get_fireball_projectile_type() -> StringName:
	return projectile_source_type


func _start_summon_preview(duration: float, direction: Vector2) -> void:
	summon_pivot.rotation = direction.angle()
	for preview in summon_previews:
		preview.visible = true
		preview.stop()
		preview.frame = 0
		preview.frame_progress = 0.0
		preview.play(&"spawn")
	summon_animation_player.stop()
	var authored_duration := maxf(
		summon_animation_player.get_animation(&"summon").length,
		0.01
	)
	summon_animation_player.play(
		&"summon",
		-1.0,
		authored_duration / maxf(duration, 0.01)
	)
	summon_animation_player.advance(0.0)


func _hide_summon_previews() -> void:
	if summon_animation_player != null:
		summon_animation_player.stop()
	for preview in summon_previews:
		preview.stop()
		preview.visible = false
		preview.scale = Vector2.ZERO


func _cancel_summon(restore_move_animation := true) -> void:
	var had_active_summon := combat_state == CombatState.SUMMON
	combat_state = CombatState.CHASE
	summon_time_left = 0.0
	summon_target = null
	_hide_summon_previews()
	var fire_config := config as FireConfig
	if restore_move_animation and fire_config != null:
		_play_config_animation(fire_config.move_animation_name)
	if had_active_summon and not is_dead:
		_broadcast_enemy_action(&"cancel", summon_direction)
	_reset_ranged_attack_position_state()


func play_multiplayer_enemy_action(
	action_name: StringName,
	direction: Vector2,
	action_id: int
) -> void:
	if action_id <= latest_proxy_action_id:
		return
	latest_proxy_action_id = action_id
	var fire_config := config as FireConfig
	if fire_config == null:
		return
	var safe_direction := (
		direction.normalized()
		if direction != Vector2.ZERO
		else Vector2.RIGHT
	)
	_update_facing(safe_direction)
	if action_name == &"summon":
		_play_multiplayer_proxy_action_animation(
			fire_config.windup_animation_name,
			fire_config.summon_duration + 0.15
		)
		_start_summon_preview(fire_config.summon_duration, safe_direction)
		_schedule_proxy_summon_preview_timeout(
			action_id,
			fire_config.summon_duration + 0.2
		)
	elif action_name == &"fire":
		_hide_summon_previews()
		_play_multiplayer_proxy_action_animation(
			fire_config.attack_animation_name,
			_get_scene_animation_duration(
				fire_config.attack_animation_name
			) + 0.05
		)
	elif action_name == &"cancel":
		_hide_summon_previews()
		_play_config_animation(fire_config.move_animation_name)


func _schedule_proxy_summon_preview_timeout(
	action_id: int,
	timeout: float
) -> void:
	if not is_inside_tree():
		return
	var timeout_tween := create_tween()
	timeout_tween.tween_interval(maxf(timeout, 0.01))
	timeout_tween.tween_callback(
		_expire_proxy_summon_preview.bind(action_id)
	)


func _expire_proxy_summon_preview(action_id: int) -> void:
	if (
		action_id != latest_proxy_action_id
		or is_dead
		or config == null
	):
		return
	_hide_summon_previews()
	var fire_config := config as FireConfig
	if (
		fire_config != null
		and animated_sprite.animation == fire_config.windup_animation_name
	):
		_play_config_animation(fire_config.move_animation_name)
