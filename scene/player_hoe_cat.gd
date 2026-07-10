extends Player
class_name PlayerHoeCat

const ENEMY_BODY_MASK := 4
const ATTACK_QUERY_BATCH_SIZE := 64
const BASIC_ATTACK_RADIUS := 8.0
const BASIC_ATTACK_ANGLE_DEGREES := 60.0
const WHIRLWIND_RADIUS := 15.0
const WHIRLWIND_DAMAGE_MULTIPLIER := 2.8
const WHIRLWIND_HEAL_AMOUNT := 3
const PRIMARY_VISUAL_DURATION := 0.3125
const PRIMARY_IMPACT_DELAY := 0.1125
const WHIRLWIND_VISUAL_DURATION := 0.5
const WHIRLWIND_IMPACT_DELAY := 0.125

@export var basic_attack_query_shape: CircleShape2D
@export var whirlwind_query_shape: CircleShape2D
@onready var basic_slash_effect: AnimatedSprite2D = $BasicSlashEffect
@onready var whirlwind_range_effect: AnimatedSprite2D = $WhirlwindRangeEffect
@onready var whirlwind_body_effect: AnimatedSprite2D = $WhirlwindBodyEffect
@onready var primary_impact_timer: Timer = $PrimaryImpactTimer
@onready var whirlwind_impact_timer: Timer = $WhirlwindImpactTimer
var _primary_visual_time_left: float = 0.0
var _primary_visual_facing_suffix: StringName = &""
var _whirlwind_visual_time_left: float = 0.0
var _pending_primary_attack: bool = false
var _pending_primary_direction: Vector2 = Vector2.ZERO
var _pending_primary_damage: int = 0
var _pending_whirlwind_attack: bool = false
var _pending_whirlwind_damage: int = 0
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
	if _whirlwind_visual_time_left > 0.0 or _pending_whirlwind_attack:
		return false
	var cardinal_direction := _get_cardinal_attack_direction(attack_direction)
	last_attack_direction = cardinal_direction
	var current_scene := get_tree().current_scene
	if current_scene != null and current_scene.has_method("request_hoe_primary_attack"):
		return bool(current_scene.call("request_hoe_primary_attack", cardinal_direction))
	return try_authoritative_hoe_primary_attack(cardinal_direction)


func try_authoritative_hoe_primary_attack(attack_direction: Vector2) -> bool:
	if (
		is_dead
		or controls_locked
		or _whirlwind_visual_time_left > 0.0
		or _pending_whirlwind_attack
		or _pending_primary_attack
	):
		return false
	if shooting_timer == null or not shooting_timer.is_stopped():
		return false
	var cardinal_direction := _get_cardinal_attack_direction(attack_direction)
	last_attack_direction = cardinal_direction
	_pending_primary_attack = true
	_pending_primary_direction = cardinal_direction
	_pending_primary_damage = get_hoe_primary_attack_damage()
	notify_primary_attack_performed()
	shooting_timer.start(_get_effective_fire_interval())
	_update_attack_interval_bar()
	_play_primary_attack_visual(cardinal_direction)
	return true


func _try_use_skill1() -> bool:
	if not skill1_unlocked:
		return false
	if (
		is_dead
		or controls_locked
		or _primary_visual_time_left > 0.0
		or _pending_primary_attack
		or _whirlwind_visual_time_left > 0.0
		or _pending_whirlwind_attack
	):
		return false
	_sync_skill1_charge_duration_to_upgrade_level()
	if skill1_charge < skill1_charge_duration:
		return false
	var current_scene := get_tree().current_scene
	if current_scene != null and current_scene.has_method("request_hoe_whirlwind"):
		return bool(current_scene.call("request_hoe_whirlwind"))
	return try_authoritative_hoe_whirlwind()


func try_authoritative_hoe_whirlwind() -> bool:
	if (
		is_dead
		or controls_locked
		or _primary_visual_time_left > 0.0
		or _pending_primary_attack
		or _whirlwind_visual_time_left > 0.0
		or _pending_whirlwind_attack
	):
		return false
	if not consume_multiplayer_skill1_charge():
		return false
	_pending_whirlwind_attack = true
	_pending_whirlwind_damage = get_hoe_whirlwind_damage()
	_play_whirlwind_visual()
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
			var cardinal_direction := _get_cardinal_attack_direction(attack_direction)
			last_attack_direction = cardinal_direction
			_play_primary_attack_visual(cardinal_direction)
		&"whirlwind":
			_play_whirlwind_visual()


func _apply_hoe_attack_damage(
	query_shape: CircleShape2D,
	attack_radius: float,
	attack_direction: Vector2,
	half_angle: float,
	damage: int
) -> int:
	var space_state := get_world_2d().direct_space_state
	if space_state == null or query_shape == null or damage <= 0 or attack_radius <= 0.0:
		return 0
	if not is_equal_approx(query_shape.radius, attack_radius):
		push_error(
			"Hoe Cat attack query radius mismatch: scene=%s, combat=%s"
			% [query_shape.radius, attack_radius]
		)
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
	for result in results:
		var enemy := result.get("collider") as Enemy
		if enemy == null or not is_instance_valid(enemy) or enemy.is_dead:
			continue
		var enemy_id := enemy.get_instance_id()
		if hit_enemy_ids.has(enemy_id):
			continue
		var offset := enemy.global_position - global_position
		var offset_length_squared := offset.length_squared()
		# The CircleShape2D query already enforces the authored radius against the
		# enemy collision shape. A second centre-distance test made the radius-8
		# swing unusable: normal enemies stop on touch while their centres are still
		# roughly 11.5-13.5 pixels apart. Keep only the centre-based cone test.
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


func _get_cardinal_attack_direction(attack_direction: Vector2) -> Vector2:
	var safe_direction := _get_safe_attack_direction(attack_direction)
	return _facing_suffix_to_vector(_vector_to_facing_suffix(safe_direction))


func _update_character_combat_state(delta: float) -> void:
	var had_primary_visual := _primary_visual_time_left > 0.0
	_primary_visual_time_left = maxf(_primary_visual_time_left - maxf(delta, 0.0), 0.0)
	if had_primary_visual and _primary_visual_time_left <= 0.0:
		_primary_visual_facing_suffix = &""
		basic_slash_effect.hide()
		basic_slash_effect.stop()
	if _whirlwind_visual_time_left <= 0.0:
		return
	_whirlwind_visual_time_left = maxf(_whirlwind_visual_time_left - maxf(delta, 0.0), 0.0)
	if _whirlwind_visual_time_left <= 0.0:
		_finish_whirlwind_visual()


func _update_animation() -> void:
	if _whirlwind_visual_time_left > 0.0:
		return
	if _primary_visual_time_left > 0.0:
		_play_primary_attack_body_animation(false)
		return
	if velocity.length_squared() <= 0.01:
		var idle_animation := StringName("idle_%s" % facing_suffix)
		if body_sprite.sprite_frames.has_animation(idle_animation):
			if body_sprite.animation != idle_animation or not body_sprite.is_playing():
				body_sprite.play(idle_animation)
			return
	super._update_animation()


func _play_primary_attack_visual(attack_direction: Vector2) -> void:
	_primary_visual_time_left = PRIMARY_VISUAL_DURATION
	_update_facing(Vector2.ZERO, attack_direction)
	_primary_visual_facing_suffix = facing_suffix
	_play_primary_attack_body_animation(true)
	basic_slash_effect.rotation = attack_direction.angle()
	basic_slash_effect.frame = 0
	basic_slash_effect.show()
	basic_slash_effect.play(&"slash")
	primary_impact_timer.start(PRIMARY_IMPACT_DELAY)


func _play_primary_attack_body_animation(restart: bool) -> void:
	var locked_facing := (
		_primary_visual_facing_suffix
		if not _primary_visual_facing_suffix.is_empty()
		else facing_suffix
	)
	var animation_name := StringName("attack_%s" % locked_facing)
	if not body_sprite.sprite_frames.has_animation(animation_name):
		animation_name = &"attack"
	if not body_sprite.sprite_frames.has_animation(animation_name):
		return
	# A non-looping attack that reaches its final frame must remain there until
	# the visual lock expires. Restarting it from _update_animation made one swing
	# look like overlapping/repeated frames. A new attack explicitly restarts it.
	if restart or body_sprite.animation != animation_name:
		body_sprite.play(animation_name)


func _play_whirlwind_visual() -> void:
	_finish_whirlwind_visual()
	_primary_visual_time_left = 0.0
	_primary_visual_facing_suffix = &""
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
	whirlwind_impact_timer.start(WHIRLWIND_IMPACT_DELAY)


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


func _on_primary_impact_timer_timeout() -> void:
	_play_primary_attack_audio()
	if not _pending_primary_attack:
		return
	var impact_direction := _pending_primary_direction
	var impact_damage := _pending_primary_damage
	_pending_primary_attack = false
	_pending_primary_direction = Vector2.ZERO
	_pending_primary_damage = 0
	if is_dead or controls_locked:
		return
	_apply_hoe_attack_damage(
		basic_attack_query_shape,
		BASIC_ATTACK_RADIUS,
		impact_direction,
		deg_to_rad(BASIC_ATTACK_ANGLE_DEGREES * 0.5),
		impact_damage
	)


func _on_whirlwind_impact_timer_timeout() -> void:
	_play_whirlwind_audio()
	if not _pending_whirlwind_attack:
		return
	var impact_damage := _pending_whirlwind_damage
	_pending_whirlwind_attack = false
	_pending_whirlwind_damage = 0
	if is_dead or controls_locked:
		return
	_apply_hoe_attack_damage(
		whirlwind_query_shape,
		WHIRLWIND_RADIUS,
		Vector2.ZERO,
		PI,
		impact_damage
	)
	_apply_authoritative_player_heal(self, WHIRLWIND_HEAL_AMOUNT)
	_activate_collectible_skill_effects()


func _play_primary_attack_audio() -> void:
	if gunshot_audio != null and gunshot_audio.stream != null:
		gunshot_audio.pitch_scale = randf_range(0.96, 1.04)
		gunshot_audio.play()


func _play_whirlwind_audio() -> void:
	if gunload_audio != null and gunload_audio.stream != null:
		gunload_audio.pitch_scale = randf_range(0.96, 1.04)
		gunload_audio.play()
