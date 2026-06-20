extends YuanshiInsect
class_name YuanshiInsectExploder

const EXPLOSION_QUERY_MAX_RESULTS := 16

@onready var explosion_area: Area2D = $ExplosionArea
@onready var explosion_shape: CollisionShape2D = $ExplosionArea/CollisionShape2D
@onready var explosion_audio: AudioStreamPlayer2D = $ExplosionAudio


func _apply_config() -> void:
	super._apply_config()

	if config == null:
		return

	_apply_explosion_radius(config.explosion_radius)


# 将配置中的爆炸半径同步到一次性爆炸检测区。
func _apply_explosion_radius(radius: float) -> void:
	var explosion_circle_shape := explosion_shape.shape as CircleShape2D
	if explosion_circle_shape != null:
		explosion_circle_shape.radius = maxf(radius, 0.0)


func _finish_after_death_animation() -> void:
	if death_sequence_stage == DeathSequenceStage.DEATH and _should_play_explosion_sequence():
		_start_explosion_sequence()
		return

	super._finish_after_death_animation()


func _should_play_explosion_sequence() -> bool:
	return config != null and config.explode_on_death


# 自爆阶段开始时才结算爆炸伤害，确保表现和逻辑同步。
func _start_explosion_sequence() -> void:
	if not _should_play_explosion_sequence():
		queue_free()
		return

	animated_sprite.scale = Vector2.ONE * maxf(config.explosion_animation_scale, 0.1)
	explosion_audio.play()
	_try_apply_explosion_damage()

	if _play_death_sequence_animation(config.explosion_animation_name, DeathSequenceStage.EXPLOSION):
		return

	queue_free()


func _try_apply_explosion_damage() -> void:
	if config == null:
		return
	if not config.explode_on_death:
		return
	if config.explosion_damage <= 0 or config.explosion_radius <= 0.0:
		return
	if explosion_shape.shape == null:
		return

	var space_state := get_world_2d().direct_space_state
	if space_state == null:
		return

	var query := PhysicsShapeQueryParameters2D.new()
	query.shape = explosion_shape.shape
	query.transform = explosion_shape.global_transform
	query.collision_mask = explosion_area.collision_mask
	query.collide_with_bodies = true
	query.collide_with_areas = false
	query.exclude = [get_rid()]

	var query_results := space_state.intersect_shape(query, EXPLOSION_QUERY_MAX_RESULTS)
	if query_results.is_empty():
		return

	var damaged_collider_ids: Dictionary = {}
	for result in query_results:
		var collider := result.get("collider") as Node
		if collider == null:
			continue
		if collider == self:
			continue

		var collider_id := collider.get_instance_id()
		if damaged_collider_ids.has(collider_id):
			continue
		damaged_collider_ids[collider_id] = true

		var hit_player := collider as Player
		if hit_player != null:
			_apply_multiplayer_player_damage(
				hit_player,
				config.explosion_damage,
				_get_multiplayer_damage_source_id(900000),
				&"yuanshi_explosion"
			)
			continue

		var hit_enemy := collider as Enemy
		if hit_enemy != null:
			hit_enemy.apply_damage(config.explosion_damage)
