extends Player
class_name PlayerHoeCat

const ENEMY_BODY_MASK := 4
const ATTACK_QUERY_BATCH_SIZE := 64
const BASIC_ATTACK_RADIUS := 8.0
const BASIC_ATTACK_ANGLE_DEGREES := 60.0
const WHIRLWIND_RADIUS := 15.0
const WHIRLWIND_DAMAGE_MULTIPLIER := 2.8
const WHIRLWIND_HEAL_AMOUNT := 3
const PRIMARY_VISUAL_DURATION := 0.25
const WHIRLWIND_VISUAL_DURATION := 0.5

@export var basic_attack_query_shape: CircleShape2D
@export var whirlwind_query_shape: CircleShape2D
@onready var hoe_sprite: Sprite2D = $BodySprite/HoeSprite
@onready var basic_slash_effect: AnimatedSprite2D = $BasicSlashEffect
@onready var whirlwind_range_effect: AnimatedSprite2D = $WhirlwindRangeEffect
@onready var whirlwind_body_effect: AnimatedSprite2D = $WhirlwindBodyEffect
@onready var action_animation_player: AnimationPlayer = $ActionAnimationPlayer
var _primary_visual_time_left: float = 0.0
var _whirlwind_visual_time_left: float = 0.0
var _latest_remote_action_sequence: int = 0


func _init() -> void:
	character_id = &"hoe_cat"
	move_speed = 120.0
	max_health = 80
	attack_damage = 15
	attack_method_name = "锄头"
	fire_interval = 0.5
	attack_speed_units_per_attack = 200.0
	ammo_capacity = 1


func uses_ammunition() -> bool:
	return false


func supports_projectile_attack_patterns() -> bool:
	return false


func uses_attack_interval_bar() -> bool:
	return true


func is_hoe_cat() -> bool:
	return true


func get_hoe_primary_attack_damage() -> int:
	return get_outgoing_damage(attack_damage, EnemyConfig.DamageType.PHYSICAL)


func get_hoe_whirlwind_damage() -> int:
	return get_outgoing_damage(
		floori(float(attack_damage) * WHIRLWIND_DAMAGE_MULTIPLIER),
		EnemyConfig.DamageType.PHYSICAL
	)


func _perform_primary_attack(attack_direction: Vector2) -> bool:
	if _whirlwind_visual_time_left > 0.0:
		return false
	var safe_direction := _get_safe_attack_direction(attack_direction)
	last_attack_direction = safe_direction
	var current_scene := get_tree().current_scene
	if current_scene != null and current_scene.has_method("request_hoe_primary_attack"):
		return bool(current_scene.call("request_hoe_primary_attack", safe_direction))
	return try_authoritative_hoe_primary_attack(safe_direction)


func try_authoritative_hoe_primary_attack(attack_direction: Vector2) -> bool:
	if is_dead or controls_locked or _whirlwind_visual_time_left > 0.0:
		return false
	if shooting_timer == null or not shooting_timer.is_stopped():
		return false
	var safe_direction := _get_safe_attack_direction(attack_direction)
	last_attack_direction = safe_direction
	_apply_hoe_attack_damage(
		basic_attack_query_shape,
		BASIC_ATTACK_RADIUS,
		safe_direction,
		deg_to_rad(BASIC_ATTACK_ANGLE_DEGREES * 0.5),
		get_hoe_primary_attack_damage()
	)
	notify_primary_attack_performed()
	shooting_timer.start(_get_effective_fire_interval())
	_update_attack_interval_bar()
	_play_primary_attack_visual(safe_direction)
	_play_primary_attack_audio()
	return true


func _try_use_skill1() -> bool:
	if not skill1_unlocked:
		return false
	if is_dead or controls_locked or _whirlwind_visual_time_left > 0.0:
		return false
	_sync_skill1_charge_duration_to_upgrade_level()
	if skill1_charge < skill1_charge_duration:
		return false
	var current_scene := get_tree().current_scene
	if current_scene != null and current_scene.has_method("request_hoe_whirlwind"):
		return bool(current_scene.call("request_hoe_whirlwind"))
	return try_authoritative_hoe_whirlwind()


func try_authoritative_hoe_whirlwind() -> bool:
	if _whirlwind_visual_time_left > 0.0:
		return false
	if not consume_multiplayer_skill1_charge():
		return false
	_apply_hoe_attack_damage(
		whirlwind_query_shape,
		WHIRLWIND_RADIUS,
		Vector2.ZERO,
		PI,
		get_hoe_whirlwind_damage()
	)
	_apply_authoritative_player_heal(self, WHIRLWIND_HEAL_AMOUNT)
	_activate_collectible_skill_effects()
	_play_whirlwind_visual()
	_play_whirlwind_audio()
	return true


func play_remote_hoe_action(
	action_kind: StringName,
	attack_direction: Vector2,
	sequence: int
) -> void:
	if sequence <= _latest_remote_action_sequence:
		return
	_latest_remote_action_sequence = sequence
	match action_kind:
		&"primary":
			var safe_direction := _get_safe_attack_direction(attack_direction)
			last_attack_direction = safe_direction
			_play_primary_attack_visual(safe_direction)
			_play_primary_attack_audio()
		&"whirlwind":
			_play_whirlwind_visual()
			_play_whirlwind_audio()


func _apply_hoe_attack_damage(
	query_shape: CircleShape2D,
	attack_radius: float,
	attack_direction: Vector2,
	half_angle: float,
	damage: int
) -> int:
	var space_state := get_world_2d().direct_space_state
	if space_state == null or query_shape == null or damage <= 0:
		return 0
	var query := PhysicsShapeQueryParameters2D.new()
	query.shape = query_shape
	query.transform = Transform2D(0.0, global_position)
	query.collision_mask = ENEMY_BODY_MASK
	query.collide_with_bodies = true
	query.collide_with_areas = false
	var results: Array[Dictionary] = []
	var excluded_rids: Array[RID] = []
	var excluded_rid_set: Dictionary = {}
	while true:
		query.exclude = excluded_rids
		var result_batch := space_state.intersect_shape(query, ATTACK_QUERY_BATCH_SIZE)
		var newly_excluded := 0
		for result in result_batch:
			results.append(result)
			var collision_object := result.get("collider") as CollisionObject2D
			if collision_object == null:
				continue
			var collider_rid := collision_object.get_rid()
			if excluded_rid_set.has(collider_rid):
				continue
			excluded_rid_set[collider_rid] = true
			excluded_rids.append(collider_rid)
			newly_excluded += 1
		if result_batch.size() < ATTACK_QUERY_BATCH_SIZE or newly_excluded == 0:
			break
	var hit_enemy_ids: Dictionary = {}
	var hit_count := 0
	var attack_radius_squared := attack_radius * attack_radius
	for result in results:
		var enemy := result.get("collider") as Enemy
		if enemy == null or not is_instance_valid(enemy) or enemy.is_dead:
			continue
		var enemy_id := enemy.get_instance_id()
		if hit_enemy_ids.has(enemy_id):
			continue
		var offset := enemy.global_position - global_position
		var offset_length_squared := offset.length_squared()
		if offset_length_squared > attack_radius_squared:
			continue
		if (
			attack_direction != Vector2.ZERO
			and offset_length_squared > 0.001
			and abs(attack_direction.angle_to(offset.normalized())) > half_angle + 0.0001
		):
			continue
		hit_enemy_ids[enemy_id] = true
		var impact_direction := global_position.direction_to(enemy.global_position)
		if impact_direction == Vector2.ZERO:
			impact_direction = attack_direction if attack_direction != Vector2.ZERO else Vector2.DOWN
		if not _apply_authoritative_collectible_enemy_damage(
			enemy,
			damage,
			impact_direction,
			EnemyConfig.DamageType.PHYSICAL
		):
			continue
		hit_count += 1
		apply_collectible_attack_hit_effects(enemy, damage)
	return hit_count


func _get_safe_attack_direction(attack_direction: Vector2) -> Vector2:
	if (
		is_finite(attack_direction.x)
		and is_finite(attack_direction.y)
		and attack_direction.length_squared() > 0.001
	):
		return attack_direction.normalized()
	var facing_direction := _facing_suffix_to_vector(facing_suffix)
	return facing_direction if facing_direction != Vector2.ZERO else Vector2.RIGHT


func _update_character_combat_state(delta: float) -> void:
	var had_primary_visual := _primary_visual_time_left > 0.0
	_primary_visual_time_left = maxf(_primary_visual_time_left - maxf(delta, 0.0), 0.0)
	if had_primary_visual and _primary_visual_time_left <= 0.0:
		basic_slash_effect.hide()
		basic_slash_effect.stop()
	_update_hoe_sprite()
	if _whirlwind_visual_time_left <= 0.0:
		return
	_whirlwind_visual_time_left = maxf(_whirlwind_visual_time_left - maxf(delta, 0.0), 0.0)
	if _whirlwind_visual_time_left <= 0.0:
		_finish_whirlwind_visual()


func _update_animation() -> void:
	if _whirlwind_visual_time_left > 0.0:
		return
	if _primary_visual_time_left > 0.0:
		var directional_attack := StringName("attack_%s" % facing_suffix)
		if body_sprite.sprite_frames.has_animation(directional_attack):
			if body_sprite.animation != directional_attack or not body_sprite.is_playing():
				body_sprite.play(directional_attack)
			return
		if body_sprite.sprite_frames.has_animation(&"attack"):
			if body_sprite.animation != &"attack" or not body_sprite.is_playing():
				body_sprite.play(&"attack")
			return
	super._update_animation()
	_update_hoe_sprite()


func _play_primary_attack_visual(attack_direction: Vector2) -> void:
	_primary_visual_time_left = PRIMARY_VISUAL_DURATION
	_update_hoe_sprite()
	_update_facing(Vector2.ZERO, attack_direction)
	_update_animation()
	basic_slash_effect.rotation = attack_direction.angle()
	basic_slash_effect.frame = 0
	basic_slash_effect.show()
	basic_slash_effect.play(&"slash")
	action_animation_player.play(&"basic_slash")


func _play_whirlwind_visual() -> void:
	_finish_whirlwind_visual()
	_primary_visual_time_left = 0.0
	basic_slash_effect.hide()
	basic_slash_effect.stop()
	_whirlwind_visual_time_left = WHIRLWIND_VISUAL_DURATION
	body_sprite.visible = false
	whirlwind_body_effect.frame = 0
	whirlwind_body_effect.show()
	whirlwind_body_effect.play(&"whirlwind")
	whirlwind_range_effect.frame = 0
	whirlwind_range_effect.show()
	whirlwind_range_effect.play(&"whirlwind")
	action_animation_player.play(&"whirlwind")


func _finish_whirlwind_visual() -> void:
	_whirlwind_visual_time_left = 0.0
	if whirlwind_body_effect != null:
		whirlwind_body_effect.hide()
		whirlwind_body_effect.stop()
	if whirlwind_range_effect != null:
		whirlwind_range_effect.hide()
		whirlwind_range_effect.stop()
	if body_sprite != null:
		body_sprite.visible = true
	_update_hoe_sprite()


func _update_hoe_sprite() -> void:
	if hoe_sprite == null:
		return
	hoe_sprite.visible = (
		not is_dead
		and _primary_visual_time_left <= 0.0
		and _whirlwind_visual_time_left <= 0.0
	)
	if not hoe_sprite.visible:
		return
	match facing_suffix:
		&"up":
			hoe_sprite.position = Vector2(-5.0, -2.0)
			hoe_sprite.rotation = -0.68
			hoe_sprite.z_index = -1
		&"left":
			hoe_sprite.position = Vector2(-6.0, 0.0)
			hoe_sprite.rotation = -1.2
			hoe_sprite.z_index = 1
		&"right":
			hoe_sprite.position = Vector2(6.0, 0.0)
			hoe_sprite.rotation = 0.38
			hoe_sprite.z_index = 1
		_:
			hoe_sprite.position = Vector2(5.0, 1.0)
			hoe_sprite.rotation = 0.78
			hoe_sprite.z_index = 1


func _play_primary_attack_audio() -> void:
	if gunshot_audio != null and gunshot_audio.stream != null:
		gunshot_audio.pitch_scale = randf_range(0.96, 1.04)
		gunshot_audio.play()


func _play_whirlwind_audio() -> void:
	if gunload_audio != null and gunload_audio.stream != null:
		gunload_audio.pitch_scale = randf_range(0.96, 1.04)
		gunload_audio.play()
