extends CharacterBody2D
class_name Enemy

signal defeated(enemy: Enemy)

const BLINK_ENABLED_SHADER_PARAMETER := &"blink_enabled"

enum DeathSequenceStage {
	NONE,
	DEATH,
	EXPLOSION,
}

@export var config: EnemyConfig
@export var touch_damage_interval: float = 0.5
@export var hurt_blink_duration: float = 0.16

@onready var animated_sprite: AnimatedSprite2D = $AnimatedSprite2D
@onready var collision_shape: CollisionShape2D = $CollisionShape2D
@onready var touch_damage_area: Area2D = $TouchDamageArea
@onready var touch_damage_shape: CollisionShape2D = $TouchDamageArea/CollisionShape2D
@onready var hit_particles: GPUParticles2D = $HitParticles
@onready var hit_audio: AudioStreamPlayer2D = $HitAudio
@onready var death_audio: AudioStreamPlayer2D = $DeathAudio

var target_player: Player = null
var pathfinder: Node = null
var current_health: int = 1
var is_dead: bool = false
var touch_damage_cooldown_left: float = 0.0
var touched_player: Player = null
var hurt_blink_time_left: float = 0.0
var death_sequence_stage: DeathSequenceStage = DeathSequenceStage.NONE
var death_animation_name_in_use: StringName = &""
var physical_defense_modifiers: Dictionary = {}


func _ready() -> void:
	touch_damage_area.body_entered.connect(_on_touch_damage_area_body_entered)
	touch_damage_area.body_exited.connect(_on_touch_damage_area_body_exited)
	touch_damage_area.area_entered.connect(_on_touch_damage_area_area_entered)
	animated_sprite.animation_finished.connect(_on_animated_sprite_animation_finished)
	_apply_config()


func setup(enemy_config: EnemyConfig, player: Player, shared_pathfinder: Node = null) -> void:
	config = enemy_config
	target_player = player
	pathfinder = shared_pathfinder
	_apply_config()


func set_target_player(player: Player) -> void:
	target_player = player


func set_pathfinder(shared_pathfinder: Node) -> void:
	pathfinder = shared_pathfinder


func apply_damage(
	amount: int,
	impact_direction: Vector2 = Vector2.ZERO,
	damage_type: EnemyConfig.DamageType = EnemyConfig.DamageType.PHYSICAL
) -> bool:
	if is_dead:
		return false
	if amount <= 0:
		return false

	_play_hit_particles(impact_direction)
	var final_damage := _calculate_incoming_damage(amount, damage_type)
	current_health -= final_damage

	if current_health <= 0:
		_die()
		return true

	hit_audio.play()
	_start_hurt_blink()
	return true


func add_physical_defense_modifier(source_id: int, amount: int) -> void:
	if source_id == 0:
		return
	if amount <= 0:
		return

	physical_defense_modifiers[source_id] = amount


func remove_physical_defense_modifier(source_id: int) -> void:
	physical_defense_modifiers.erase(source_id)


func get_effective_physical_defense() -> int:
	var total := config.physical_defense if config != null else 0
	for modifier in physical_defense_modifiers.values():
		total += maxi(modifier as int, 0)
	return maxi(total, 0)


func get_effective_magic_defense() -> int:
	return clampi(config.magic_defense if config != null else 0, 0, 100)


func _calculate_incoming_damage(
	amount: int,
	damage_type: EnemyConfig.DamageType
) -> int:
	match damage_type:
		EnemyConfig.DamageType.MAGIC:
			var defense_ratio := float(100 - get_effective_magic_defense()) / 100.0
			return maxi(floori(float(amount) * defense_ratio), 1)
		_:
			return maxi(amount - get_effective_physical_defense(), 1)


func _apply_config() -> void:
	if config == null:
		return

	current_health = config.max_health
	_apply_collision_radius(config.collision_radius)

	if config.enemy_frames != null:
		animated_sprite.sprite_frames = config.enemy_frames
		if config.enemy_frames.has_animation(config.move_animation_name):
			animated_sprite.play(config.move_animation_name)
		else:
			push_warning("Missing enemy move animation: %s" % config.move_animation_name)


func _apply_collision_radius(radius: float) -> void:
	var body_shape := collision_shape.shape as CircleShape2D
	if body_shape != null:
		body_shape.radius = radius

	var damage_shape := touch_damage_shape.shape as CircleShape2D
	if damage_shape != null:
		damage_shape.radius = radius


func _on_touch_damage_area_body_entered(body: Node2D) -> void:
	if is_dead:
		return

	var player := body as Player
	if player == null:
		return

	touched_player = player
	_try_deal_touch_damage()


func _on_touch_damage_area_body_exited(body: Node2D) -> void:
	if body == touched_player:
		touched_player = null


func _on_touch_damage_area_area_entered(area: Area2D) -> void:
	if is_dead:
		return

	var bullet := area as Bullet
	if bullet == null:
		return

	var damaged := apply_damage(bullet.damage, -bullet.direction)
	if damaged:
		bullet.queue_free()


func _update_touch_damage(delta: float) -> void:
	if touch_damage_cooldown_left > 0.0:
		touch_damage_cooldown_left = maxf(touch_damage_cooldown_left - delta, 0.0)

	if touched_player == null:
		return
	if not is_instance_valid(touched_player):
		touched_player = null
		return
	if touch_damage_cooldown_left > 0.0:
		return

	_try_deal_touch_damage()


func _try_deal_touch_damage() -> void:
	if touched_player == null:
		return
	if config == null:
		return

	touched_player.apply_damage(config.attack_damage)
	touch_damage_cooldown_left = touch_damage_interval


func _start_hurt_blink() -> void:
	hurt_blink_time_left = hurt_blink_duration
	_set_hurt_blink_enabled(true)


func _update_hurt_blink(delta: float) -> void:
	if hurt_blink_time_left <= 0.0:
		return

	hurt_blink_time_left = maxf(hurt_blink_time_left - delta, 0.0)
	if hurt_blink_time_left > 0.0:
		return

	_set_hurt_blink_enabled(false)


func _set_hurt_blink_enabled(enabled: bool) -> void:
	var sprite_material := animated_sprite.material as ShaderMaterial
	if sprite_material != null:
		sprite_material.set_shader_parameter(BLINK_ENABLED_SHADER_PARAMETER, enabled)


func _play_hit_particles(impact_direction: Vector2) -> void:
	if impact_direction == Vector2.ZERO:
		return

	hit_particles.rotation = impact_direction.angle()
	hit_particles.restart()
	hit_particles.emitting = true


func _die() -> void:
	if is_dead:
		return

	is_dead = true
	defeated.emit(self)
	velocity = Vector2.ZERO
	touched_player = null
	hurt_blink_time_left = 0.0
	_set_hurt_blink_enabled(false)
	collision_shape.set_deferred("disabled", true)
	touch_damage_shape.set_deferred("disabled", true)
	touch_damage_area.set_deferred("monitoring", false)
	touch_damage_area.set_deferred("monitorable", false)
	death_audio.play()
	_start_death_sequence()


func _start_death_sequence() -> void:
	if config == null:
		queue_free()
		return

	if _play_death_sequence_animation(config.death_animation_name, DeathSequenceStage.DEATH):
		return

	_finish_after_death_animation()


func _finish_after_death_animation() -> void:
	queue_free()


func _play_death_sequence_animation(animation_name: StringName, stage: DeathSequenceStage) -> bool:
	death_sequence_stage = stage
	death_animation_name_in_use = animation_name

	if config == null:
		return false
	if config.enemy_frames == null:
		return false
	if not config.enemy_frames.has_animation(animation_name):
		return false

	animated_sprite.play(animation_name)
	return true


func _on_animated_sprite_animation_finished() -> void:
	if not is_dead:
		return
	if death_animation_name_in_use == &"":
		return
	if animated_sprite.animation != death_animation_name_in_use:
		return

	_finish_after_death_animation()
