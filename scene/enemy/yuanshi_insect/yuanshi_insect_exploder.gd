extends YuanshiInsect
class_name YuanshiInsectExploder

const EXPLOSION_AUDIO_LIMITER := preload("res://scene/explosion_audio_limiter.gd")
const COMPLETE_SHAPE_QUERY_2D := preload("res://scene/complete_shape_query_2d.gd")
const NIGHT_VFX_FLASH_POOL := preload("res://scene/lighting/night_vfx_flash_pool.gd")
const EXPLOSION_QUERY_BATCH_SIZE := 64

@export var explosion_flash_color := Color(1.0, 0.52, 0.2, 1.0)
@export_range(0.0, 4.0, 0.01, "or_greater") var explosion_flash_energy := 0.9
@export_range(0.01, 2.0, 0.01, "or_greater") var explosion_flash_texture_scale := 0.65

@onready var explosion_area: Area2D = $ExplosionArea
@onready var explosion_shape: CollisionShape2D = $ExplosionArea/CollisionShape2D
@onready var explosion_audio: AudioStreamPlayer2D = $ExplosionAudio
@onready var explosion_emission_overlay: AnimatedSprite2D = (
	$AnimatedSprite2D/ExplosionEmissionOverlay
)

var explosion_damage_done := false
var outgoing_explosion_damage_snapshot := 0


func _apply_config() -> void:
	super._apply_config()
	outgoing_explosion_damage_snapshot = 0

	if config == null:
		return

	_apply_explosion_radius(config.explosion_radius)


func _die() -> void:
	if is_dead:
		return
	outgoing_explosion_damage_snapshot = (
		get_effective_attack_damage(config.explosion_damage)
		if config != null
		else 0
	)
	super._die()


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
	animated_sprite.z_index = 8
	explosion_emission_overlay.flip_h = animated_sprite.flip_h
	explosion_emission_overlay.flip_v = animated_sprite.flip_v
	explosion_emission_overlay.visible = true
	explosion_emission_overlay.play(config.explosion_animation_name)
	NIGHT_VFX_FLASH_POOL.request_from(
		self,
		global_position,
		explosion_flash_color,
		explosion_flash_energy,
		explosion_flash_texture_scale,
		0.035,
		0.05,
		0.25,
		2
	)
	EXPLOSION_AUDIO_LIMITER.play(explosion_audio)
	if not is_multiplayer_proxy:
		_try_apply_explosion_damage()

	if _play_death_sequence_animation(config.explosion_animation_name, DeathSequenceStage.EXPLOSION):
		return

	queue_free()


func _try_apply_explosion_damage() -> void:
	if explosion_damage_done:
		return
	if config == null:
		return
	if not config.explode_on_death:
		return
	if config.explosion_damage <= 0 or config.explosion_radius <= 0.0:
		return
	if explosion_shape.shape == null:
		return
	# Normal death flow snapshots before Enemy clears timed statuses. Keep direct
	# test/editor invocation deterministic without replacing a valid death snapshot.
	if outgoing_explosion_damage_snapshot <= 0:
		outgoing_explosion_damage_snapshot = get_effective_attack_damage(
			config.explosion_damage
		)

	var space_state := get_world_2d().direct_space_state
	if space_state == null:
		return
	explosion_damage_done = true

	var query := PhysicsShapeQueryParameters2D.new()
	query.shape = explosion_shape.shape
	query.transform = explosion_shape.global_transform
	query.collision_mask = explosion_area.collision_mask
	query.collide_with_bodies = true
	query.collide_with_areas = false
	query.exclude = [get_rid()]

	var query_results := COMPLETE_SHAPE_QUERY_2D.intersect_shape_all(
		space_state,
		query,
		EXPLOSION_QUERY_BATCH_SIZE
	)
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
				outgoing_explosion_damage_snapshot,
				_get_multiplayer_damage_source_id(900000),
				&"yuanshi_explosion"
			)
			continue

		var hit_enemy := collider as Enemy
		if hit_enemy != null:
			hit_enemy.apply_damage(config.explosion_damage)
