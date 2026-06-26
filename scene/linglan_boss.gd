extends Enemy
class_name LinglanBoss

signal health_changed(current_health: int, maximum_health: int)
signal boss_defeated

const SKILL2_AUDIO_LIMITER := preload("res://scene/explosion_audio_limiter.gd")

@export var starts_active: bool = false
@export var boss_display_name: String = "铃兰"
@export var skill1_config: LinglanSkillConfig
@export var skill2_config: LinglanSkill2Config
@export var skill3_config: LinglanSkill3Config

@onready var skill2_fire_audio: AudioStreamPlayer2D = get_node_or_null("Skill2FireAudio") as AudioStreamPlayer2D

enum BossSkillPhase {
	SKILL1,
	MOVE_TO_SKILL2,
	SKILL2,
	MOVE_TO_SKILL3,
	SKILL3,
	DONE,
}

var is_active: bool = false
var skill3_random := RandomNumberGenerator.new()
var boss_skill_phase: BossSkillPhase = BossSkillPhase.SKILL1
var skill1_elapsed: float = 0.0
var skill1_fire_time_left: float = 0.0
var skill1_finished: bool = false
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


func _ready() -> void:
	super._ready()
	skill3_random.randomize()
	set_active(starts_active)
	_emit_health_changed()


func setup(enemy_config: EnemyConfig, player: Player, shared_pathfinder: Node = null) -> void:
	super.setup(enemy_config, player, shared_pathfinder)
	_emit_health_changed()


func activate_boss(player: Player, shared_pathfinder: Node = null) -> void:
	setup(config, player, shared_pathfinder)
	_reset_skill_state()
	boss_skill_phase = BossSkillPhase.SKILL1
	set_active(true)
	if animated_sprite != null and not is_dead:
		animated_sprite.play(&"idle")


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
		_reset_skill_state()


func apply_damage(
	amount: int,
	impact_direction: Vector2 = Vector2.ZERO,
	damage_type: EnemyConfig.DamageType = EnemyConfig.DamageType.PHYSICAL
) -> bool:
	var accepted := super.apply_damage(amount, impact_direction, damage_type)
	if accepted:
		_emit_health_changed()
	return accepted


func _physics_process(delta: float) -> void:
	if not is_active or is_dead:
		velocity = Vector2.ZERO
		return
	_update_touch_damage(delta)
	match boss_skill_phase:
		BossSkillPhase.SKILL1:
			_update_skill1(delta)
			velocity = Vector2.ZERO
			if skill1_finished:
				_begin_skill2_move()
		BossSkillPhase.MOVE_TO_SKILL2:
			_update_skill2_move(delta)
		BossSkillPhase.SKILL2:
			_update_skill2(delta)
		BossSkillPhase.MOVE_TO_SKILL3:
			_update_skill3_move(delta)
		BossSkillPhase.SKILL3:
			_update_skill3(delta)
		_:
			velocity = Vector2.ZERO
			_play_idle_animation()


func _die() -> void:
	if is_dead:
		return
	boss_defeated.emit()
	_reset_skill_state()
	super._die()
	_emit_health_changed()


func get_max_health() -> int:
	return config.max_health if config != null else 0


func _emit_health_changed() -> void:
	health_changed.emit(maxi(current_health, 0), get_max_health())


func apply_multiplayer_health_snapshot(new_current_health: int) -> void:
	current_health = maxi(new_current_health, 0)
	_emit_health_changed()


func _reset_skill_state() -> void:
	_reset_skill1_state()
	_reset_skill2_state()
	_reset_skill3_state()
	boss_skill_phase = BossSkillPhase.SKILL1


func _reset_skill1_state() -> void:
	skill1_elapsed = 0.0
	skill1_fire_time_left = 0.0
	skill1_finished = false
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

	var skill_elapsed := skill1_elapsed - skill1_config.start_delay
	if skill_elapsed >= skill1_config.get_total_duration():
		skill1_finished = true
		return

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
	move_and_slide()


func _begin_skill2_attack() -> void:
	boss_skill_phase = BossSkillPhase.SKILL2
	skill2_elapsed = 0.0
	skill2_spawn_ticks_completed = 0
	skill2_shots_fired = 0
	skill2_warning_shot_index = -1
	velocity = Vector2.ZERO
	_play_idle_animation()


func _update_skill2(delta: float) -> void:
	velocity = Vector2.ZERO
	skill2_elapsed += maxf(delta, 0.0)
	_play_idle_animation()
	_update_skill2_spawn_ticks()
	_update_skill2_warning_and_fire()
	if (
		skill2_elapsed >= skill2_config.get_total_duration()
		and skill2_shots_fired >= maxi(skill2_config.attack_count, 1)
	):
		_clear_skill2_warning_arrow()
		_begin_skill3_move()


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
	move_and_slide()


func _begin_skill3_attack() -> void:
	boss_skill_phase = BossSkillPhase.SKILL3
	skill3_elapsed = 0.0
	skill3_shots_fired = 0
	velocity = Vector2.ZERO
	_play_idle_animation()


func _update_skill3(delta: float) -> void:
	velocity = Vector2.ZERO
	skill3_elapsed += maxf(delta, 0.0)
	_play_idle_animation()
	_update_skill3_fire()
	if skill3_elapsed >= skill3_config.duration and skill3_shots_fired >= skill3_config.get_shot_count():
		boss_skill_phase = BossSkillPhase.DONE


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


func _clear_skill2_warning_arrow() -> void:
	if skill2_warning_arrow != null and is_instance_valid(skill2_warning_arrow):
		skill2_warning_arrow.queue_free()
	skill2_warning_arrow = null
	skill2_warning_shot_index = -1
