extends Enemy
class_name LinglanBoss

signal health_changed(current_health: int, maximum_health: int)
signal boss_defeated

const SKILL2_AUDIO_LIMITER := preload("res://scene/explosion_audio_limiter.gd")
const LinglanSkill4ConfigScript := preload("res://resources/config/bosses/linglan_skill4_config.gd")
const LinglanSkill4LaserFieldScript := preload("res://scene/linglan_skill4_laser_field.gd")
const LinglanSkill4LightOrbScript := preload("res://scene/linglan_skill4_light_orb.gd")
const ENRAGE_SNIPER_CONFIG := preload("res://resources/config/enemies/capoo_sniper.tres")
const AIRDROP_WARNING_SCENE := preload("res://scene/linglan_airdrop_warning_marker.tscn")
const OPENING_SKILL_ORDER := [1, 2, 3, 4]
const POST_SKILL_IDLE_DURATION := 2.0
const ENRAGE_SNIPER_HEALTH_RATIO := 0.5
const ENRAGE_SNIPER_INTERVAL := 10.0
const ENRAGE_SNIPER_WARNING_DURATION := 1.2
const ENRAGE_SNIPER_DROP_HEIGHT := 180.0
const ENRAGE_SNIPER_DROP_DURATION := 0.5

@export var starts_active: bool = false
@export var boss_display_name: String = "铃兰"
@export var skill1_config: LinglanSkillConfig
@export var skill2_config: LinglanSkill2Config
@export var skill3_config: LinglanSkill3Config
@export var skill4_config: Resource

@onready var skill2_fire_audio: AudioStreamPlayer2D = get_node_or_null("Skill2FireAudio") as AudioStreamPlayer2D

enum BossSkillPhase {
	SKILL1,
	MOVE_TO_SKILL2,
	SKILL2,
	MOVE_TO_SKILL3,
	SKILL3,
	MOVE_TO_SKILL4,
	SKILL4,
	POST_SKILL_IDLE,
	DONE,
}

var is_active: bool = false
var skill3_random := RandomNumberGenerator.new()
var skill4_random := RandomNumberGenerator.new()
var skill_order_random := RandomNumberGenerator.new()
var action_sequence: int = 0
var latest_proxy_action_id: int = 0
var boss_skill_phase: BossSkillPhase = BossSkillPhase.SKILL1
var opening_skill_order_index: int = 0
var queued_skill_number: int = 0
var post_skill_idle_elapsed: float = 0.0
var random_skill_use_counts: Dictionary = {}
var enrage_sniper_active: bool = false
var enrage_sniper_timer: float = ENRAGE_SNIPER_INTERVAL
var skill1_elapsed: float = 0.0
var skill1_fire_time_left: float = 0.0
var skill1_finished: bool = false
var skill1_attack_broadcast_sent: bool = false
var skill1_warning_broadcast_sent: bool = false
var skill1_warning_rays: Array[Node2D] = []
var skill2_target_global_position := Vector2.ZERO
var skill2_elapsed: float = 0.0
var skill2_spawn_ticks_completed: int = 0
var skill2_shots_fired: int = 0
var skill2_warning_shot_index: int = -1
var skill2_warning_arrow: Node2D = null
var skill2_pending_direction := Vector2.RIGHT
var skill2_pending_target_player: Player = null
var skill3_target_global_position := Vector2.ZERO
var skill3_elapsed: float = 0.0
var skill3_shots_fired: int = 0
var skill4_target_global_position := Vector2.ZERO
var skill4_elapsed: float = 0.0
var skill4_orb_spawn_ticks_completed: int = 0
var skill4_laser_field: Node = null


func _ready() -> void:
	super._ready()
	skill3_random.randomize()
	skill4_random.randomize()
	skill_order_random.randomize()
	set_active(starts_active)
	_emit_health_changed()


func setup(enemy_config: EnemyConfig, player: Player, shared_pathfinder: Node = null) -> void:
	super.setup(enemy_config, player, shared_pathfinder)
	_emit_health_changed()


func configure_multiplayer_proxy() -> void:
	super.configure_multiplayer_proxy()
	visible = true
	_set_collision_shapes_disabled(body_collision_shapes, false)
	_set_collision_shapes_disabled(touch_damage_shapes, true)
	if touch_damage_area != null:
		touch_damage_area.set_deferred("monitoring", false)
		touch_damage_area.set_deferred("monitorable", false)


func apply_multiplayer_proxy_motion(proxy_position: Vector2, proxy_velocity: Vector2) -> void:
	global_position = proxy_position
	velocity = proxy_velocity
	_set_facing_from_direction(proxy_velocity)
	if not skill1_warning_rays.is_empty():
		_update_skill1_warning_ray_transforms()
	_play_proxy_locomotion_animation()


func activate_boss(player: Player, shared_pathfinder: Node = null) -> void:
	setup(config, player, shared_pathfinder)
	_reset_skill_state()
	set_active(true)
	_begin_skill_number(1)


func set_active(active: bool) -> void:
	is_active = active
	visible = active
	set_process(active)
	set_physics_process(active)
	if touch_damage_area != null:
		touch_damage_area.set_deferred("monitoring", active)
		touch_damage_area.set_deferred("monitorable", active)
	_set_collision_shapes_disabled(body_collision_shapes, not active)
	_set_collision_shapes_disabled(touch_damage_shapes, not active)
	if not active:
		_clear_touching_players()
		_reset_skill_state()


func apply_damage(
	amount: int,
	impact_direction: Vector2 = Vector2.ZERO,
	damage_type: EnemyConfig.DamageType = EnemyConfig.DamageType.PHYSICAL,
	show_hit_particles: bool = true
) -> bool:
	var accepted := super.apply_damage(
		amount,
		impact_direction,
		damage_type,
		show_hit_particles
	)
	if accepted:
		_emit_health_changed()
	return accepted


func _physics_process(delta: float) -> void:
	if not is_active or is_dead:
		velocity = Vector2.ZERO
		return
	_update_touch_damage(delta)
	_update_enrage_sniper_airdrops(delta)
	match boss_skill_phase:
		BossSkillPhase.SKILL1:
			_update_skill1(delta)
			velocity = Vector2.ZERO
			if skill1_finished:
				_finish_skill(1)
		BossSkillPhase.MOVE_TO_SKILL2:
			_update_skill2_move(delta)
		BossSkillPhase.SKILL2:
			_update_skill2(delta)
		BossSkillPhase.MOVE_TO_SKILL3:
			_update_skill3_move(delta)
		BossSkillPhase.SKILL3:
			_update_skill3(delta)
		BossSkillPhase.MOVE_TO_SKILL4:
			_update_skill4_move(delta)
		BossSkillPhase.SKILL4:
			_update_skill4(delta)
		BossSkillPhase.POST_SKILL_IDLE:
			_update_post_skill_idle(delta)
		_:
			velocity = Vector2.ZERO
			_play_idle_animation()


func _die() -> void:
	if is_dead:
		return
	_pause_background_music_for_death()
	boss_defeated.emit()
	_reset_skill_state()
	super._die()
	_emit_health_changed()


func play_multiplayer_death_sequence() -> void:
	latest_proxy_action_id += 1
	_clear_skill1_warning_rays()
	_clear_skill2_warning_arrow()
	_clear_skill4_laser_field()
	super.play_multiplayer_death_sequence()


func get_max_health() -> int:
	return config.max_health if config != null else 0


func _emit_health_changed() -> void:
	health_changed.emit(maxi(current_health, 0), get_max_health())


func apply_multiplayer_health_snapshot(new_current_health: int) -> void:
	current_health = maxi(new_current_health, 0)
	_emit_health_changed()


func _pause_background_music_for_death() -> void:
	var host := _find_parent_with_method(&"pause_all_background_music")
	if host != null:
		host.call("pause_all_background_music")


func _reset_skill_state() -> void:
	action_sequence = 0
	latest_proxy_action_id = 0
	opening_skill_order_index = 0
	queued_skill_number = 0
	post_skill_idle_elapsed = 0.0
	_reset_random_skill_use_counts()
	enrage_sniper_active = false
	enrage_sniper_timer = ENRAGE_SNIPER_INTERVAL
	_reset_skill1_state()
	_reset_skill2_state()
	_reset_skill3_state()
	_reset_skill4_state()
	boss_skill_phase = BossSkillPhase.SKILL1


func _begin_skill_number(skill_number: int) -> void:
	match skill_number:
		1:
			_begin_skill1_attack()
		2:
			_begin_skill2_move()
		3:
			_begin_skill3_move()
		4:
			_begin_skill4_move()
		_:
			boss_skill_phase = BossSkillPhase.DONE
			_play_idle_animation()


func _begin_skill1_attack() -> void:
	_reset_skill1_state()
	if not _is_skill1_ready():
		boss_skill_phase = BossSkillPhase.DONE
		_play_idle_animation()
		return
	boss_skill_phase = BossSkillPhase.SKILL1
	velocity = Vector2.ZERO
	_play_idle_animation()


func _finish_skill(skill_number: int) -> void:
	match skill_number:
		1:
			_clear_skill1_warning_rays()
		2:
			_clear_skill2_warning_arrow()
		4:
			_clear_skill4_laser_field()

	queued_skill_number = _get_next_skill_number(skill_number)
	post_skill_idle_elapsed = 0.0
	velocity = Vector2.ZERO
	_play_idle_animation()
	if queued_skill_number <= 0:
		boss_skill_phase = BossSkillPhase.DONE
		return
	boss_skill_phase = BossSkillPhase.POST_SKILL_IDLE


func _get_next_skill_number(completed_skill_number: int) -> int:
	var completed_opening_index := OPENING_SKILL_ORDER.find(completed_skill_number)
	if (
		completed_opening_index >= 0
		and completed_opening_index >= opening_skill_order_index
	):
		opening_skill_order_index = completed_opening_index + 1

	if opening_skill_order_index < OPENING_SKILL_ORDER.size():
		return int(OPENING_SKILL_ORDER[opening_skill_order_index])

	return _pick_random_ready_skill_number(completed_skill_number)


func _pick_random_ready_skill_number(previous_skill_number: int) -> int:
	var ready_skills := _get_ready_skill_numbers()
	var candidate_skills: Array[int] = []
	for skill_number in ready_skills:
		if skill_number != previous_skill_number:
			candidate_skills.append(skill_number)
	if candidate_skills.is_empty():
		return 0

	var least_used_skills: Array[int] = []
	var least_use_count := 2147483647
	for skill_number in candidate_skills:
		var use_count := int(random_skill_use_counts.get(skill_number, 0))
		if use_count < least_use_count:
			least_use_count = use_count
			least_used_skills = [skill_number]
		elif use_count == least_use_count:
			least_used_skills.append(skill_number)

	var selected_skill: int = least_used_skills[skill_order_random.randi_range(0, least_used_skills.size() - 1)]
	random_skill_use_counts[selected_skill] = int(random_skill_use_counts.get(selected_skill, 0)) + 1
	return selected_skill


func _get_ready_skill_numbers() -> Array[int]:
	var ready_skills: Array[int] = []
	if _is_skill1_ready():
		ready_skills.append(1)
	if _is_skill2_ready():
		ready_skills.append(2)
	if _is_skill3_ready():
		ready_skills.append(3)
	if _is_skill4_ready():
		ready_skills.append(4)
	return ready_skills


func _reset_random_skill_use_counts() -> void:
	random_skill_use_counts.clear()
	for skill_number in OPENING_SKILL_ORDER:
		random_skill_use_counts[int(skill_number)] = 0


func _update_post_skill_idle(delta: float) -> void:
	velocity = Vector2.ZERO
	_play_idle_animation()
	post_skill_idle_elapsed += maxf(delta, 0.0)
	if post_skill_idle_elapsed < POST_SKILL_IDLE_DURATION:
		return
	var next_skill := queued_skill_number
	queued_skill_number = 0
	_begin_skill_number(next_skill)


func _update_enrage_sniper_airdrops(delta: float) -> void:
	var maximum_health := get_max_health()
	if maximum_health <= 0:
		return
	if float(current_health) > float(maximum_health) * ENRAGE_SNIPER_HEALTH_RATIO:
		return
	if not enrage_sniper_active:
		enrage_sniper_active = true
		enrage_sniper_timer = ENRAGE_SNIPER_INTERVAL

	enrage_sniper_timer -= maxf(delta, 0.0)
	if enrage_sniper_timer > 0.0:
		return
	enrage_sniper_timer += ENRAGE_SNIPER_INTERVAL
	_request_enrage_sniper_airdrop()


func _request_enrage_sniper_airdrop() -> void:
	var host := _find_parent_with_method(&"spawn_linglan_airdrop_sniper")
	if host == null:
		return
	host.call(
		"spawn_linglan_airdrop_sniper",
		ENRAGE_SNIPER_CONFIG,
		AIRDROP_WARNING_SCENE,
		ENRAGE_SNIPER_WARNING_DURATION,
		ENRAGE_SNIPER_DROP_HEIGHT,
		ENRAGE_SNIPER_DROP_DURATION
	)


func _reset_skill1_state() -> void:
	skill1_elapsed = 0.0
	skill1_fire_time_left = 0.0
	skill1_finished = false
	skill1_attack_broadcast_sent = false
	skill1_warning_broadcast_sent = false
	_clear_skill1_warning_rays()


func _reset_skill2_state() -> void:
	skill2_target_global_position = Vector2.ZERO
	skill2_elapsed = 0.0
	skill2_spawn_ticks_completed = 0
	skill2_shots_fired = 0
	skill2_warning_shot_index = -1
	skill2_pending_direction = Vector2.RIGHT
	skill2_pending_target_player = null
	_clear_skill2_warning_arrow()


func _reset_skill3_state() -> void:
	skill3_target_global_position = Vector2.ZERO
	skill3_elapsed = 0.0
	skill3_shots_fired = 0


func _reset_skill4_state() -> void:
	skill4_target_global_position = Vector2.ZERO
	skill4_elapsed = 0.0
	skill4_orb_spawn_ticks_completed = 0
	_clear_skill4_laser_field()


func _is_skill1_ready() -> bool:
	return skill1_config != null and skill1_config.projectile_scene != null


func _update_skill1(delta: float) -> void:
	if skill1_config == null or skill1_finished:
		return
	if skill1_config.projectile_scene == null:
		return

	var previous_elapsed := skill1_elapsed
	skill1_elapsed += delta
	if skill1_elapsed < skill1_config.start_delay:
		_update_skill1_warning_rays()
		return
	_clear_skill1_warning_rays()

	var skill_active_delta := delta
	if previous_elapsed < skill1_config.start_delay:
		skill_active_delta = skill1_elapsed - skill1_config.start_delay
		skill1_fire_time_left = 0.0
		if not skill1_attack_broadcast_sent:
			skill1_attack_broadcast_sent = true
			_broadcast_enemy_action(&"linglan_skill1_attack", Vector2.ZERO)

	var skill_elapsed := skill1_elapsed - skill1_config.start_delay
	if skill_elapsed >= skill1_config.get_total_duration():
		skill1_finished = true
		return

	_play_attack_animation()
	skill1_fire_time_left -= maxf(skill_active_delta, 0.0)
	var fire_interval := skill1_config.get_fire_interval()
	while skill1_fire_time_left <= 0.0 and not skill1_finished:
		var ring_skill_elapsed := clampf(
			skill_elapsed + skill1_fire_time_left,
			0.0,
			skill1_config.get_total_duration()
		)
		if ring_skill_elapsed >= skill1_config.get_total_duration():
			skill1_finished = true
			return
		_fire_skill1_ring(ring_skill_elapsed)
		skill1_fire_time_left += fire_interval


func _fire_skill1_ring(skill_elapsed: float) -> void:
	var direction_count := maxi(skill1_config.ring_direction_count, 1)
	var angle_step := TAU / float(direction_count)
	var base_angle := _get_skill1_base_angle(skill_elapsed)
	for index in range(direction_count):
		var direction := Vector2.RIGHT.rotated(base_angle + angle_step * float(index))
		_spawn_skill1_projectile(direction)


func _get_skill1_base_angle(skill_elapsed: float) -> float:
	if skill_elapsed <= skill1_config.fixed_fire_duration:
		return 0.0
	var rotating_elapsed := skill_elapsed - skill1_config.fixed_fire_duration
	return deg_to_rad(skill1_config.rotation_speed_degrees_per_second) * rotating_elapsed


func _spawn_skill1_projectile(direction: Vector2) -> void:
	var projectile := skill1_config.projectile_scene.instantiate() as LinglanSakuraBullet
	if projectile == null:
		return

	var spawn_parent := get_tree().current_scene
	if spawn_parent == null:
		projectile.free()
		return

	projectile.top_level = true
	projectile.setup(
		direction,
		skill1_config.projectile_damage,
		skill1_config.projectile_speed,
		skill1_config.projectile_lifetime
	)
	spawn_parent.add_child(projectile)
	projectile.global_position = global_position + direction * skill1_config.projectile_spawn_distance
	_register_multiplayer_projectile(projectile, projectile.global_position, direction)


func _register_multiplayer_projectile(
	projectile: LinglanSakuraBullet,
	spawn_position: Vector2,
	projectile_direction: Vector2
) -> void:
	var current_scene := get_tree().current_scene
	if current_scene == null or not current_scene.has_method("register_local_projectile"):
		return
	current_scene.call(
		"register_local_projectile",
		projectile,
		&"linglan_skill1",
		get_multiplayer_authority(),
		spawn_position,
		projectile_direction,
		skill1_config.projectile_damage,
		skill1_config.projectile_speed,
		skill1_config.projectile_lifetime,
		false
	)


func _update_skill1_warning_rays() -> void:
	if skill1_config.warning_ray_scene == null:
		return
	var warning_start_elapsed := maxf(skill1_config.start_delay - skill1_config.warning_lead_time, 0.0)
	if skill1_elapsed < warning_start_elapsed:
		return
	if skill1_warning_rays.is_empty():
		_spawn_skill1_warning_rays()
		if not skill1_warning_rays.is_empty() and not skill1_warning_broadcast_sent:
			skill1_warning_broadcast_sent = true
			_broadcast_enemy_action(&"linglan_skill1_warning", Vector2.ZERO)
	_update_skill1_warning_ray_transforms()


func _spawn_skill1_warning_rays() -> void:
	var spawn_parent := get_tree().current_scene
	if spawn_parent == null:
		return

	var direction_count := maxi(skill1_config.ring_direction_count, 1)
	for index in range(direction_count):
		var ray := skill1_config.warning_ray_scene.instantiate() as Node2D
		if ray == null:
			continue
		ray.top_level = true
		ray.name = "LinglanSkill1WarningRay%02d" % index
		_apply_skill1_warning_ray_geometry(ray)
		spawn_parent.add_child(ray)
		skill1_warning_rays.append(ray)


func _apply_skill1_warning_ray_geometry(ray: Node2D) -> void:
	var start_distance := skill1_config.projectile_spawn_distance
	var end_distance := start_distance + skill1_config.get_projectile_travel_distance()
	var ray_points := PackedVector2Array([
		Vector2(start_distance, 0.0),
		Vector2(end_distance, 0.0)
	])
	var glow := ray.get_node("Glow") as Line2D
	var core := ray.get_node("Core") as Line2D
	var center := ray.get_node("Center") as Line2D
	glow.points = ray_points
	core.points = ray_points
	center.points = ray_points


func _update_skill1_warning_ray_transforms() -> void:
	var direction_count := skill1_warning_rays.size()
	if direction_count <= 0:
		return

	var angle_step := TAU / float(direction_count)
	var warning_progress := _get_skill1_warning_progress()
	var width_scale := skill1_config.warning_ray_width_scale * (0.85 + 0.2 * warning_progress)
	var ray_alpha := lerpf(0.35, 0.82, warning_progress)
	for index in range(direction_count):
		var ray := skill1_warning_rays[index]
		if not is_instance_valid(ray):
			continue
		var direction := Vector2.RIGHT.rotated(angle_step * float(index))
		ray.global_position = global_position
		ray.global_rotation = direction.angle()
		ray.scale = Vector2(1.0, width_scale)
		ray.modulate.a = ray_alpha


func _get_skill1_warning_progress() -> float:
	if skill1_config.warning_lead_time <= 0.0:
		return 1.0
	var warning_start_elapsed := maxf(skill1_config.start_delay - skill1_config.warning_lead_time, 0.0)
	return clampf(
		(skill1_elapsed - warning_start_elapsed) / skill1_config.warning_lead_time,
		0.0,
		1.0
	)


func _clear_skill1_warning_rays() -> void:
	for ray in skill1_warning_rays:
		if is_instance_valid(ray):
			ray.queue_free()
	skill1_warning_rays.clear()


func _begin_skill2_move() -> void:
	_clear_skill1_warning_rays()
	_reset_skill2_state()
	if not _is_skill2_ready():
		boss_skill_phase = BossSkillPhase.DONE
		_play_idle_animation()
		return
	skill2_target_global_position = _resolve_skill2_target_global_position()
	boss_skill_phase = BossSkillPhase.MOVE_TO_SKILL2
	if animated_sprite != null and animated_sprite.sprite_frames != null:
		if animated_sprite.sprite_frames.has_animation(&"move"):
			animated_sprite.play(&"move")


func _is_skill2_ready() -> bool:
	return (
		skill2_config != null
		and skill2_config.rocket_scene != null
		and skill2_config.warning_arrow_scene != null
	)


func _update_skill2_move(delta: float) -> void:
	if _has_player_contact():
		velocity = Vector2.ZERO
		return
	var offset := skill2_target_global_position - global_position
	var distance := offset.length()
	var move_speed := skill2_config.move_speed
	var arrival_distance := maxf(skill2_config.arrival_distance, 0.0)
	if distance <= maxf(arrival_distance, move_speed * delta):
		global_position = skill2_target_global_position
		velocity = Vector2.ZERO
		_begin_skill2_attack()
		return

	var move_direction := offset / distance
	_set_facing_from_direction(move_direction)
	if animated_sprite != null and animated_sprite.animation != &"move":
		_play_scene_animation(&"move")
	velocity = move_direction * move_speed
	_move_until_player_contact()


func _begin_skill2_attack() -> void:
	boss_skill_phase = BossSkillPhase.SKILL2
	skill2_elapsed = 0.0
	skill2_spawn_ticks_completed = 0
	skill2_shots_fired = 0
	skill2_warning_shot_index = -1
	velocity = Vector2.ZERO
	_play_attack_animation()
	_broadcast_enemy_action(&"linglan_skill2_attack", Vector2.ZERO)


func _update_skill2(delta: float) -> void:
	velocity = Vector2.ZERO
	skill2_elapsed += maxf(delta, 0.0)
	_play_attack_animation()
	_update_skill2_spawn_ticks()
	_update_skill2_warning_and_fire()
	if (
		skill2_elapsed >= skill2_config.get_total_duration()
		and skill2_shots_fired >= maxi(skill2_config.attack_count, 1)
	):
		_finish_skill(2)


func _update_skill2_spawn_ticks() -> void:
	var attack_count := maxi(skill2_config.attack_count, 1)
	var attack_interval := maxf(skill2_config.attack_interval, 0.05)
	while skill2_spawn_ticks_completed < attack_count:
		var spawn_time := float(skill2_spawn_ticks_completed) * attack_interval
		if skill2_elapsed + 0.0001 < spawn_time:
			return
		_request_skill2_spawn_adds()
		skill2_spawn_ticks_completed += 1


func _update_skill2_warning_and_fire() -> void:
	var attack_count := maxi(skill2_config.attack_count, 1)
	if skill2_shots_fired >= attack_count:
		return

	var attack_interval := maxf(skill2_config.attack_interval, 0.05)
	var shot_index := skill2_shots_fired
	var warning_start_time := float(shot_index) * attack_interval
	if skill2_elapsed + 0.0001 < warning_start_time:
		return

	if skill2_warning_shot_index != shot_index:
		_spawn_skill2_warning_arrow(shot_index)
	_update_skill2_warning_arrow()

	var fire_time := warning_start_time + maxf(skill2_config.warning_lead_time, 0.0)
	if skill2_elapsed + 0.0001 < fire_time:
		return

	_fire_skill2_rocket()
	skill2_shots_fired += 1
	_clear_skill2_warning_arrow()


func _spawn_skill2_warning_arrow(shot_index: int) -> void:
	_clear_skill2_warning_arrow()
	var spawn_parent := _get_effect_spawn_parent()
	if spawn_parent == null:
		return
	var arrow := skill2_config.warning_arrow_scene.instantiate() as Node2D
	if arrow == null:
		return
	arrow.top_level = true
	arrow.name = "LinglanSkill2WarningArrow%02d" % shot_index
	_apply_skill2_warning_arrow_geometry(arrow)
	spawn_parent.add_child(arrow)
	skill2_warning_arrow = arrow
	skill2_warning_shot_index = shot_index


func _apply_skill2_warning_arrow_geometry(arrow: Node2D) -> void:
	var start_distance := skill2_config.warning_arrow_start_distance
	var end_distance := start_distance + skill2_config.warning_arrow_length
	_set_skill2_arrow_polygon(arrow, "GlowArrow", start_distance, end_distance, 6.0, 12.0, 18.0, 6.0)
	_set_skill2_arrow_polygon(arrow, "CoreArrow", start_distance, end_distance, 3.5, 8.0, 14.0, 5.0)
	_set_skill2_arrow_polygon(arrow, "HighlightArrow", start_distance + 5.0, end_distance, 1.4, 3.6, 12.0, 4.0)


func _set_skill2_arrow_polygon(
	arrow: Node2D,
	node_name: String,
	tail_x: float,
	end_x: float,
	body_half_height: float,
	head_half_height: float,
	head_length: float,
	tip_extra_length: float
) -> void:
	var polygon_node := arrow.get_node_or_null(node_name) as Polygon2D
	if polygon_node == null:
		return
	var shoulder_x := maxf(tail_x, end_x - head_length)
	var tip_x := end_x + tip_extra_length
	polygon_node.polygon = PackedVector2Array([
		Vector2(tail_x, -body_half_height),
		Vector2(shoulder_x, -body_half_height),
		Vector2(shoulder_x, -head_half_height),
		Vector2(tip_x, 0.0),
		Vector2(shoulder_x, head_half_height),
		Vector2(shoulder_x, body_half_height),
		Vector2(tail_x, body_half_height),
	])


func _update_skill2_warning_arrow() -> void:
	_update_skill2_pending_target()
	if skill2_warning_arrow == null or not is_instance_valid(skill2_warning_arrow):
		return
	skill2_warning_arrow.global_position = global_position
	skill2_warning_arrow.global_rotation = skill2_pending_direction.angle()
	var warning_progress := _get_skill2_warning_progress()
	skill2_warning_arrow.modulate.a = lerpf(0.42, 0.88, warning_progress)


func _get_skill2_warning_progress() -> float:
	if skill2_warning_shot_index < 0:
		return 0.0
	var lead_time := maxf(skill2_config.warning_lead_time, 0.001)
	var warning_start_time := float(skill2_warning_shot_index) * maxf(skill2_config.attack_interval, 0.05)
	return clampf((skill2_elapsed - warning_start_time) / lead_time, 0.0, 1.0)


func _fire_skill2_rocket() -> void:
	_update_skill2_pending_target()
	var projectile := skill2_config.rocket_scene.instantiate() as LinglanSkill2SakuraRocket
	if projectile == null:
		return

	var spawn_parent := _get_effect_spawn_parent()
	if spawn_parent == null:
		projectile.free()
		return

	var spawn_position := global_position + skill2_pending_direction * skill2_config.rocket_spawn_distance
	projectile.top_level = true
	projectile.setup(
		skill2_pending_direction,
		skill2_config.rocket_damage,
		skill2_config.rocket_speed,
		skill2_config.rocket_lifetime,
		skill2_config.rocket_explosion_radius,
		skill2_pending_target_player,
		skill2_config.rocket_homing_turn_rate
	)
	spawn_parent.add_child(projectile)
	projectile.global_position = spawn_position
	_play_skill2_fire_audio()
	_register_skill2_multiplayer_projectile(
		projectile,
		spawn_position,
		skill2_pending_direction,
		skill2_pending_target_player
	)


func _register_skill2_multiplayer_projectile(
	projectile: LinglanSkill2SakuraRocket,
	spawn_position: Vector2,
	projectile_direction: Vector2,
	projectile_target_player: Player
) -> void:
	var current_scene := get_tree().current_scene
	if current_scene == null or not current_scene.has_method("register_local_projectile"):
		return
	var target_peer_id := projectile_target_player.peer_id if projectile_target_player != null else 0
	current_scene.call(
		"register_local_projectile",
		projectile,
		&"linglan_skill2_rocket",
		get_multiplayer_authority(),
		spawn_position,
		projectile_direction,
		skill2_config.rocket_damage,
		skill2_config.rocket_speed,
		skill2_config.rocket_lifetime,
		false,
		target_peer_id
	)


func _update_skill2_pending_target() -> void:
	skill2_pending_target_player = _pick_skill2_target_player()
	var target_position := (
		skill2_pending_target_player.global_position
		if skill2_pending_target_player != null and is_instance_valid(skill2_pending_target_player)
		else global_position + skill2_pending_direction
	)
	var next_direction := global_position.direction_to(target_position)
	if next_direction == Vector2.ZERO:
		next_direction = skill2_pending_direction
	if next_direction == Vector2.ZERO:
		next_direction = Vector2.RIGHT
	skill2_pending_direction = next_direction.normalized()


func _pick_skill2_target_player() -> Player:
	var host := _find_parent_with_method(&"get_linglan_skill2_target_player")
	if host != null:
		return host.call("get_linglan_skill2_target_player", global_position) as Player
	if target_player != null and is_instance_valid(target_player) and not target_player.is_dead:
		return target_player
	return null


func _request_skill2_spawn_adds() -> void:
	var host := _find_parent_with_method(&"spawn_linglan_skill2_enemies")
	if host == null:
		return
	host.call(
		"spawn_linglan_skill2_enemies",
		skill2_config.spawn_enemy_config,
		skill2_config.spawn_marker_names
	)


func _resolve_skill2_target_global_position() -> Vector2:
	var host := _find_parent_with_method(&"get_linglan_skill2_target_global_position")
	if host != null:
		return host.call(
			"get_linglan_skill2_target_global_position",
			skill2_config.target_cell
		) as Vector2
	return global_position


func _begin_skill3_move() -> void:
	_clear_skill2_warning_arrow()
	_reset_skill3_state()
	if not _is_skill3_ready():
		boss_skill_phase = BossSkillPhase.DONE
		_play_idle_animation()
		return
	skill3_target_global_position = _resolve_skill3_target_global_position()
	boss_skill_phase = BossSkillPhase.MOVE_TO_SKILL3
	if animated_sprite != null and animated_sprite.sprite_frames != null:
		if animated_sprite.sprite_frames.has_animation(&"move"):
			animated_sprite.play(&"move")


func _is_skill3_ready() -> bool:
	return skill3_config != null and skill3_config.orb_scene != null


func _update_skill3_move(delta: float) -> void:
	if _has_player_contact():
		velocity = Vector2.ZERO
		return
	var offset := skill3_target_global_position - global_position
	var distance := offset.length()
	var move_speed := skill3_config.move_speed
	var arrival_distance := maxf(skill3_config.arrival_distance, 0.0)
	if distance <= maxf(arrival_distance, move_speed * delta):
		global_position = skill3_target_global_position
		velocity = Vector2.ZERO
		_begin_skill3_attack()
		return

	var move_direction := offset / distance
	_set_facing_from_direction(move_direction)
	if animated_sprite != null and animated_sprite.animation != &"move":
		_play_scene_animation(&"move")
	velocity = move_direction * move_speed
	_move_until_player_contact()


func _begin_skill3_attack() -> void:
	boss_skill_phase = BossSkillPhase.SKILL3
	skill3_elapsed = 0.0
	skill3_shots_fired = 0
	velocity = Vector2.ZERO
	_play_attack_animation()
	_broadcast_enemy_action(&"linglan_skill3_attack", Vector2.ZERO)


func _update_skill3(delta: float) -> void:
	velocity = Vector2.ZERO
	skill3_elapsed += maxf(delta, 0.0)
	_play_attack_animation()
	_update_skill3_fire()
	if skill3_elapsed >= skill3_config.duration and skill3_shots_fired >= skill3_config.get_shot_count():
		_finish_skill(3)


func _update_skill3_fire() -> void:
	var shot_count := skill3_config.get_shot_count()
	var fire_interval := maxf(skill3_config.fire_interval, 0.05)
	while skill3_shots_fired < shot_count:
		var shot_time := float(skill3_shots_fired) * fire_interval
		if skill3_elapsed + 0.0001 < shot_time:
			return
		_fire_skill3_orb()
		skill3_shots_fired += 1


func _fire_skill3_orb() -> void:
	var orb := skill3_config.orb_scene.instantiate() as LinglanSkill3LightOrb
	if orb == null:
		return
	var spawn_parent := _get_effect_spawn_parent()
	if spawn_parent == null:
		orb.free()
		return

	var direction := _get_random_skill3_direction()
	var grow_delay := skill3_config.get_random_grow_delay(skill3_random)
	orb.top_level = true
	orb.setup(
		direction,
		skill3_config.orb_damage,
		skill3_config.orb_speed,
		grow_delay,
		skill3_config.orb_base_radius,
		skill3_config.orb_grow_scale,
		skill3_config.orb_expanded_hold_duration,
		skill3_config.orb_flash_lead_time
	)
	spawn_parent.add_child(orb)
	orb.global_position = global_position
	_register_skill3_multiplayer_projectile(orb, global_position, direction, grow_delay)


func _get_random_skill3_direction() -> Vector2:
	var minimum := minf(skill3_config.direction_min_degrees, skill3_config.direction_max_degrees)
	var maximum := maxf(skill3_config.direction_min_degrees, skill3_config.direction_max_degrees)
	return Vector2.RIGHT.rotated(deg_to_rad(skill3_random.randf_range(minimum, maximum))).normalized()


func _register_skill3_multiplayer_projectile(
	projectile: LinglanSkill3LightOrb,
	spawn_position: Vector2,
	projectile_direction: Vector2,
	grow_delay: float
) -> void:
	var current_scene := get_tree().current_scene
	if current_scene == null or not current_scene.has_method("register_local_projectile"):
		return
	current_scene.call(
		"register_local_projectile",
		projectile,
		&"linglan_skill3_orb",
		get_multiplayer_authority(),
		spawn_position,
		projectile_direction,
		skill3_config.orb_damage,
		skill3_config.orb_speed,
		grow_delay,
		false
	)


func _resolve_skill3_target_global_position() -> Vector2:
	var host := _find_parent_with_method(&"get_linglan_skill3_target_global_position")
	if host != null:
		return host.call(
			"get_linglan_skill3_target_global_position",
			skill3_config.target_cell
		) as Vector2
	return global_position


func _get_skill4_config() -> LinglanSkill4ConfigScript:
	return skill4_config as LinglanSkill4ConfigScript


func _begin_skill4_move() -> void:
	_reset_skill4_state()
	if not _is_skill4_ready():
		boss_skill_phase = BossSkillPhase.DONE
		_play_idle_animation()
		return
	skill4_target_global_position = _resolve_skill4_target_global_position()
	boss_skill_phase = BossSkillPhase.MOVE_TO_SKILL4
	if animated_sprite != null and animated_sprite.sprite_frames != null:
		if animated_sprite.sprite_frames.has_animation(&"move"):
			animated_sprite.play(&"move")


func _is_skill4_ready() -> bool:
	var config4 := _get_skill4_config()
	return (
		config4 != null
		and config4.laser_field_scene != null
		and config4.orb_scene != null
	)


func _update_skill4_move(delta: float) -> void:
	var config4 := _get_skill4_config()
	if config4 == null:
		boss_skill_phase = BossSkillPhase.DONE
		return
	if _has_player_contact():
		velocity = Vector2.ZERO
		return
	var offset := skill4_target_global_position - global_position
	var distance := offset.length()
	var move_speed: float = config4.move_speed
	var arrival_distance := maxf(config4.arrival_distance, 0.0)
	if distance <= maxf(arrival_distance, move_speed * delta):
		global_position = skill4_target_global_position
		velocity = Vector2.ZERO
		_begin_skill4_attack()
		return

	var move_direction := offset / distance
	_set_facing_from_direction(move_direction)
	if animated_sprite != null and animated_sprite.animation != &"move":
		_play_scene_animation(&"move")
	velocity = move_direction * move_speed
	_move_until_player_contact()


func _begin_skill4_attack() -> void:
	boss_skill_phase = BossSkillPhase.SKILL4
	skill4_elapsed = 0.0
	skill4_orb_spawn_ticks_completed = 0
	velocity = Vector2.ZERO
	_play_attack_animation()
	_spawn_skill4_laser_field(true)
	_broadcast_enemy_action(&"linglan_skill4_start", Vector2.ZERO)


func _update_skill4(delta: float) -> void:
	var config4 := _get_skill4_config()
	if config4 == null:
		boss_skill_phase = BossSkillPhase.DONE
		return
	velocity = Vector2.ZERO
	skill4_elapsed += maxf(delta, 0.0)
	_play_attack_animation()
	_update_skill4_orb_spawns()
	if (
		skill4_elapsed >= config4.get_total_duration()
		and skill4_orb_spawn_ticks_completed >= config4.get_orb_wave_count()
	):
		_finish_skill(4)


func _update_skill4_orb_spawns() -> void:
	var config4 := _get_skill4_config()
	if config4 == null:
		return
	var wave_count: int = config4.get_orb_wave_count()
	var fire_interval := maxf(config4.orb_spawn_interval, 0.05)
	var orb_start_time: float = config4.get_orb_start_time()
	while skill4_orb_spawn_ticks_completed < wave_count:
		var wave_time: float = orb_start_time + float(skill4_orb_spawn_ticks_completed) * fire_interval
		if skill4_elapsed + 0.0001 < wave_time:
			return
		_fire_skill4_orb_wave()
		skill4_orb_spawn_ticks_completed += 1


func _fire_skill4_orb_wave() -> void:
	var config4 := _get_skill4_config()
	if config4 == null:
		return
	var rows: Array[int] = config4.get_random_orb_rows(skill4_random)
	for row in rows:
		_spawn_skill4_orb(true, row)
		_spawn_skill4_orb(false, row)


func _spawn_skill4_orb(spawn_from_left: bool, y_cell: int) -> void:
	var config4 := _get_skill4_config()
	if config4 == null:
		return
	var orb := config4.orb_scene.instantiate() as LinglanSkill4LightOrbScript
	if orb == null:
		return
	var spawn_parent := _get_effect_spawn_parent()
	if spawn_parent == null:
		orb.free()
		return

	var direction := Vector2.RIGHT if spawn_from_left else Vector2.LEFT
	var spawn_position := _resolve_skill4_orb_spawn_global_position(spawn_from_left, y_cell)
	orb.top_level = true
	orb.setup(
		direction,
		config4.orb_damage,
		config4.orb_speed,
		config4.orb_lifetime,
		config4.orb_radius,
		config4.orb_damage_radius
	)
	spawn_parent.add_child(orb)
	orb.global_position = spawn_position
	_register_skill4_multiplayer_projectile(orb, spawn_position, direction)


func _register_skill4_multiplayer_projectile(
	projectile: Node,
	spawn_position: Vector2,
	projectile_direction: Vector2
) -> void:
	var config4 := _get_skill4_config()
	if config4 == null:
		return
	var current_scene := get_tree().current_scene
	if current_scene == null or not current_scene.has_method("register_local_projectile"):
		return
	current_scene.call(
		"register_local_projectile",
		projectile,
		&"linglan_skill4_orb",
		get_multiplayer_authority(),
		spawn_position,
		projectile_direction,
		config4.orb_damage,
		config4.orb_speed,
		config4.orb_lifetime,
		false
	)


func _spawn_skill4_laser_field(enable_damage: bool) -> void:
	_clear_skill4_laser_field()
	var config4 := _get_skill4_config()
	if config4 == null or config4.laser_field_scene == null:
		return
	var spawn_parent := _get_effect_spawn_parent()
	if spawn_parent == null:
		return
	var bounds := _resolve_skill4_laser_bounds()
	var field := config4.laser_field_scene.instantiate() as LinglanSkill4LaserFieldScript
	if field == null:
		return
	field.top_level = true
	spawn_parent.add_child(field)
	field.global_position = Vector2.ZERO
	field.setup(
		bounds.get("start_min", global_position) as Vector2,
		bounds.get("start_max", global_position) as Vector2,
		bounds.get("final_min", global_position) as Vector2,
		bounds.get("final_max", global_position) as Vector2,
		config4.laser_damage,
		config4.laser_core_width,
		config4.laser_shrink_duration,
		config4.laser_warning_duration,
		enable_damage,
		config4.get_total_duration()
	)
	if not enable_damage:
		field.setup_multiplayer_visual_only()
	skill4_laser_field = field


func _clear_skill4_laser_field() -> void:
	if skill4_laser_field != null and is_instance_valid(skill4_laser_field):
		if skill4_laser_field.has_method("finish"):
			skill4_laser_field.call("finish")
		else:
			skill4_laser_field.queue_free()
	skill4_laser_field = null


func _resolve_skill4_target_global_position() -> Vector2:
	var config4 := _get_skill4_config()
	if config4 == null:
		return global_position
	var host := _find_parent_with_method(&"get_linglan_skill4_target_global_position")
	if host != null:
		return host.call(
			"get_linglan_skill4_target_global_position",
			config4.target_cell_a,
			config4.target_cell_b
		) as Vector2
	return global_position


func _resolve_skill4_laser_bounds() -> Dictionary:
	var config4 := _get_skill4_config()
	if config4 == null:
		return {
			"start_min": global_position,
			"start_max": global_position,
			"final_min": global_position,
			"final_max": global_position,
		}
	var host := _find_parent_with_method(&"get_linglan_skill4_laser_bounds")
	if host != null:
		return host.call(
			"get_linglan_skill4_laser_bounds",
			config4.laser_start_left_cell_x,
			config4.laser_start_right_cell_x,
			config4.laser_start_top_cell_y,
			config4.laser_start_bottom_cell_y,
			config4.laser_inward_cell_distance
		) as Dictionary
	return {
		"start_min": global_position,
		"start_max": global_position,
		"final_min": global_position,
		"final_max": global_position,
	}


func _resolve_skill4_orb_spawn_global_position(spawn_from_left: bool, y_cell: int) -> Vector2:
	var config4 := _get_skill4_config()
	if config4 == null:
		return global_position
	var host := _find_parent_with_method(&"get_linglan_skill4_orb_spawn_global_position")
	var x_cell: int = (
		config4.laser_start_left_cell_x
		if spawn_from_left
		else config4.laser_start_right_cell_x
	)
	if host != null:
		return host.call(
			"get_linglan_skill4_orb_spawn_global_position",
			x_cell,
			y_cell
		) as Vector2
	return global_position


func play_multiplayer_enemy_action(action_name: StringName, direction: Vector2, action_id: int) -> void:
	if action_id <= latest_proxy_action_id:
		return
	latest_proxy_action_id = action_id
	var action_duration := _get_multiplayer_action_duration(action_name)
	if action_duration > 0.0:
		_play_multiplayer_proxy_action_animation(&"attack", action_duration)
	if action_name == &"linglan_skill1_warning":
		_play_skill1_warning_proxy_action(action_id)
	elif action_name == &"linglan_skill1_attack":
		_clear_skill1_warning_rays()
		_set_facing_from_direction(direction)
	elif action_name == &"linglan_skill4_start":
		var config4 := _get_skill4_config()
		if config4 != null:
			_spawn_skill4_laser_field(false)
		_set_facing_from_direction(direction)
	elif String(action_name).begins_with("linglan_skill"):
		_set_facing_from_direction(direction)


func _play_skill1_warning_proxy_action(action_id: int) -> void:
	if skill1_config == null or skill1_config.warning_ray_scene == null:
		return
	_clear_skill1_warning_rays()
	var warning_start_elapsed := maxf(skill1_config.start_delay - skill1_config.warning_lead_time, 0.0)
	var warning_duration := maxf(skill1_config.warning_lead_time, 0.0)
	skill1_elapsed = warning_start_elapsed
	_spawn_skill1_warning_rays()
	_update_skill1_warning_ray_transforms()
	if warning_duration <= 0.0 or not is_inside_tree():
		return
	var warning_action_id := action_id
	var tween := create_tween()
	var update_warning := func(progress: float) -> void:
		if latest_proxy_action_id != warning_action_id:
			return
		skill1_elapsed = warning_start_elapsed + warning_duration * progress
		_update_skill1_warning_ray_transforms()
	var clear_warning := func() -> void:
		if latest_proxy_action_id == warning_action_id:
			_clear_skill1_warning_rays()
	tween.tween_method(update_warning, 0.0, 1.0, warning_duration)
	tween.tween_callback(clear_warning)


func _get_multiplayer_action_duration(action_name: StringName) -> float:
	match action_name:
		&"linglan_skill1_attack":
			return skill1_config.get_total_duration() if skill1_config != null else 0.0
		&"linglan_skill2_attack":
			return skill2_config.get_total_duration() if skill2_config != null else 0.0
		&"linglan_skill3_attack":
			return skill3_config.duration if skill3_config != null else 0.0
		&"linglan_skill4_start":
			var config4 := _get_skill4_config()
			return config4.get_total_duration() if config4 != null else 0.0
		_:
			return 0.0


func _play_proxy_locomotion_animation() -> void:
	if not is_multiplayer_proxy:
		return
	if is_dead or animated_sprite == null:
		return
	if proxy_action_animation_name_in_use != &"":
		return
	if velocity.length_squared() > 1.0 and _has_scene_animation(&"move"):
		_play_scene_animation(&"move")
		return
	_play_idle_animation()


func _broadcast_enemy_action(action_name: StringName, direction: Vector2) -> void:
	action_sequence += 1
	var current_scene := get_tree().current_scene
	if current_scene != null and current_scene.has_method("broadcast_enemy_action"):
		current_scene.call(
			"broadcast_enemy_action",
			int(get_meta("net_id", 0)),
			action_name,
			direction,
			global_position,
			action_sequence
		)


func _find_parent_with_method(method_name: StringName) -> Node:
	var current: Node = self
	while current != null:
		if current.has_method(method_name):
			return current
		current = current.get_parent()
	var current_scene := get_tree().current_scene
	if current_scene != null and current_scene.has_method(method_name):
		return current_scene
	return null


func _get_effect_spawn_parent() -> Node:
	var current_scene := get_tree().current_scene
	if current_scene != null:
		return current_scene
	return get_parent()


func _play_skill2_fire_audio() -> void:
	if skill2_fire_audio == null:
		return
	if skill2_fire_audio.stream == null:
		return
	SKILL2_AUDIO_LIMITER.play(skill2_fire_audio)


func _play_idle_animation() -> void:
	if animated_sprite == null:
		return
	if animated_sprite.animation == &"idle" and animated_sprite.is_playing():
		return
	if animated_sprite.sprite_frames != null and animated_sprite.sprite_frames.has_animation(&"idle"):
		animated_sprite.play(&"idle")


func _play_attack_animation() -> void:
	if animated_sprite == null:
		return
	if animated_sprite.animation == &"attack" and animated_sprite.is_playing():
		return
	_play_scene_animation(&"attack")


func _clear_skill2_warning_arrow() -> void:
	if skill2_warning_arrow != null and is_instance_valid(skill2_warning_arrow):
		skill2_warning_arrow.queue_free()
	skill2_warning_arrow = null
	skill2_warning_shot_index = -1
