extends Enemy
class_name LinglanBoss

signal health_changed(current_health: int, maximum_health: int)
signal boss_defeated

@export var starts_active: bool = false
@export var boss_display_name: String = "铃兰"
@export var skill1_config: LinglanSkillConfig

var is_active: bool = false
var skill1_elapsed: float = 0.0
var skill1_fire_time_left: float = 0.0
var skill1_finished: bool = false
var skill1_warning_arrows: Array[Node2D] = []


func _ready() -> void:
	super._ready()
	set_active(starts_active)
	_emit_health_changed()


func setup(enemy_config: EnemyConfig, player: Player, shared_pathfinder: Node = null) -> void:
	super.setup(enemy_config, player, shared_pathfinder)
	_emit_health_changed()


func activate_boss(player: Player, shared_pathfinder: Node = null) -> void:
	setup(config, player, shared_pathfinder)
	_reset_skill1_state()
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
		_reset_skill1_state()


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
	_update_skill1(delta)
	velocity = Vector2.ZERO


func _die() -> void:
	if is_dead:
		return
	boss_defeated.emit()
	_reset_skill1_state()
	super._die()
	_emit_health_changed()


func get_max_health() -> int:
	return config.max_health if config != null else 0


func _emit_health_changed() -> void:
	health_changed.emit(maxi(current_health, 0), get_max_health())


func apply_multiplayer_health_snapshot(new_current_health: int) -> void:
	current_health = maxi(new_current_health, 0)
	_emit_health_changed()


func _reset_skill1_state() -> void:
	skill1_elapsed = 0.0
	skill1_fire_time_left = 0.0
	skill1_finished = false
	_clear_skill1_warning_arrows()


func _update_skill1(delta: float) -> void:
	if skill1_config == null or skill1_finished:
		return
	if skill1_config.projectile_scene == null:
		return

	var previous_elapsed := skill1_elapsed
	skill1_elapsed += delta
	if skill1_elapsed < skill1_config.start_delay:
		_update_skill1_warning_arrows()
		return
	_clear_skill1_warning_arrows()

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


func _update_skill1_warning_arrows() -> void:
	if skill1_config.warning_arrow_scene == null:
		return
	var warning_start_elapsed := maxf(skill1_config.start_delay - skill1_config.warning_lead_time, 0.0)
	if skill1_elapsed < warning_start_elapsed:
		return
	if skill1_warning_arrows.is_empty():
		_spawn_skill1_warning_arrows()
	_update_skill1_warning_arrow_transforms()


func _spawn_skill1_warning_arrows() -> void:
	var spawn_parent := get_tree().current_scene
	if spawn_parent == null:
		return

	var direction_count := maxi(skill1_config.ring_direction_count, 1)
	for index in range(direction_count):
		var arrow := skill1_config.warning_arrow_scene.instantiate() as Node2D
		if arrow == null:
			continue
		arrow.top_level = true
		arrow.name = "LinglanSkill1WarningArrow%02d" % index
		spawn_parent.add_child(arrow)
		skill1_warning_arrows.append(arrow)


func _update_skill1_warning_arrow_transforms() -> void:
	var direction_count := skill1_warning_arrows.size()
	if direction_count <= 0:
		return

	var angle_step := TAU / float(direction_count)
	var warning_progress := _get_skill1_warning_progress()
	var pulse_scale := skill1_config.warning_arrow_scale * (0.9 + 0.15 * warning_progress)
	var arrow_alpha := lerpf(0.45, 0.92, warning_progress)
	for index in range(direction_count):
		var arrow := skill1_warning_arrows[index]
		if not is_instance_valid(arrow):
			continue
		var direction := Vector2.RIGHT.rotated(angle_step * float(index))
		arrow.global_position = global_position + direction * skill1_config.warning_arrow_distance
		arrow.global_rotation = direction.angle()
		arrow.scale = Vector2.ONE * pulse_scale
		arrow.modulate.a = arrow_alpha


func _get_skill1_warning_progress() -> float:
	if skill1_config.warning_lead_time <= 0.0:
		return 1.0
	var warning_start_elapsed := maxf(skill1_config.start_delay - skill1_config.warning_lead_time, 0.0)
	return clampf(
		(skill1_elapsed - warning_start_elapsed) / skill1_config.warning_lead_time,
		0.0,
		1.0
	)


func _clear_skill1_warning_arrows() -> void:
	for arrow in skill1_warning_arrows:
		if is_instance_valid(arrow):
			arrow.queue_free()
	skill1_warning_arrows.clear()
