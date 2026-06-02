extends CharacterBody2D

class_name Player

@export var move_speed: float = 120.0
@export var fire_interval: float = 0.18
@export var bullet_spawn_distance: float = 18.0

@onready var body_sprite: AnimatedSprite2D = $BodySprite
@onready var armed_effect_sprite: AnimatedSprite2D = $ArmedEffectSprite
@onready var shooting_timer: Timer = $ShootingTimer

const BULLET_SCENE := preload("res://scene/bullet.tscn")
const NORMAL_ANIMATION_PREFIX := &"normal"
const ARMED_ANIMATION_PREFIX := &"armed"
const DEFAULT_FIRE_RATE_MULTIPLIER := 1.0
const SPIRAL_PHASE_STEP := PI / 12.0

const PLAYER_FORM_MODE_NORMAL := 0
const PLAYER_FORM_MODE_ARMED := 1
const SHOT_PATTERN_NORMAL := 0
const SHOT_PATTERN_SPIRAL := 1

var facing_suffix: StringName = &"right"
var rapid_fire_rate_multiplier: float = DEFAULT_FIRE_RATE_MULTIPLIER
var form_fire_rate_multiplier: float = DEFAULT_FIRE_RATE_MULTIPLIER
var current_form_mode: int = PLAYER_FORM_MODE_NORMAL
var current_shot_pattern: int = SHOT_PATTERN_NORMAL
var spiral_phase: float = 0.0


func _ready() -> void:
	shooting_timer.one_shot = true
	shooting_timer.wait_time = _get_effective_fire_interval()
	_update_animation()
	_update_armed_effect()


func _physics_process(_delta: float) -> void:
	var move_input := Input.get_vector("move_left", "move_right", "move_up", "move_down")
	var shoot_input := Input.get_vector("shoot_left", "shoot_right", "shoot_up", "shoot_down")

	velocity = move_input * move_speed
	move_and_slide()

	if current_shot_pattern == SHOT_PATTERN_SPIRAL:
		_try_auto_spiral_shoot()
	elif shoot_input != Vector2.ZERO:
		_try_shoot(shoot_input)

	_update_facing(move_input, shoot_input)
	_update_animation()
	_update_armed_effect()


func _update_animation() -> void:
	var animation_name := StringName("%s_%s" % [_get_animation_prefix(), facing_suffix])

	if not body_sprite.sprite_frames.has_animation(animation_name):
		var fallback_animation_name := StringName("%s_%s" % [NORMAL_ANIMATION_PREFIX, facing_suffix])
		if not body_sprite.sprite_frames.has_animation(fallback_animation_name):
			push_warning("Missing player animation: %s" % animation_name)
			return
		animation_name = fallback_animation_name

	if body_sprite.animation != animation_name:
		body_sprite.play(animation_name)


func _try_shoot(shoot_input: Vector2) -> void:
	if not shooting_timer.is_stopped():
		return

	var shoot_direction := shoot_input.normalized()
	var has_spawned_bullet := _fire_bullets(shoot_direction)

	if has_spawned_bullet:
		shooting_timer.start(_get_effective_fire_interval())


func _fire_bullets(base_direction: Vector2) -> bool:
	if current_shot_pattern == SHOT_PATTERN_SPIRAL:
		var has_spawned_forward_bullet := _spawn_bullet(base_direction)
		var has_spawned_backward_bullet := _spawn_bullet(base_direction.rotated(PI))
		spiral_phase = wrapf(spiral_phase + SPIRAL_PHASE_STEP, 0.0, TAU)
		return has_spawned_forward_bullet or has_spawned_backward_bullet

	return _spawn_bullet(base_direction)


func _spawn_bullet(shoot_direction: Vector2) -> bool:
	var bullet := BULLET_SCENE.instantiate() as Bullet
	if bullet == null:
		return false

	var spawn_parent := get_tree().current_scene
	if spawn_parent == null:
		return false

	bullet.top_level = true
	bullet.setup(shoot_direction)
	spawn_parent.add_child(bullet)
	bullet.global_position = global_position + shoot_direction * bullet_spawn_distance
	return true


func _try_auto_spiral_shoot() -> void:
	if not shooting_timer.is_stopped():
		return

	var spiral_direction := Vector2.RIGHT.rotated(spiral_phase)
	var has_spawned_bullet := _fire_bullets(spiral_direction)

	if has_spawned_bullet:
		shooting_timer.start(_get_effective_fire_interval())


func _get_effective_fire_interval() -> float:
	return max(fire_interval / _get_effective_fire_rate_multiplier(), 0.01)


func _get_effective_fire_rate_multiplier() -> float:
	if _has_active_form_override():
		return max(form_fire_rate_multiplier, 0.01)

	return max(rapid_fire_rate_multiplier, 0.01)


func _has_active_form_override() -> bool:
	return (
		current_form_mode != PLAYER_FORM_MODE_NORMAL
		or current_shot_pattern != SHOT_PATTERN_NORMAL
	)


func _update_armed_effect() -> void:
	var is_armed := current_form_mode == PLAYER_FORM_MODE_ARMED

	if not is_armed:
		if armed_effect_sprite.visible:
			armed_effect_sprite.visible = false
		if armed_effect_sprite.is_playing():
			armed_effect_sprite.stop()
		return

	if not armed_effect_sprite.visible:
		armed_effect_sprite.visible = true
	if armed_effect_sprite.is_playing():
		return
	if armed_effect_sprite.sprite_frames == null:
		return
	if armed_effect_sprite.sprite_frames.has_animation(&"default"):
		armed_effect_sprite.play(&"default")


func _get_animation_prefix() -> StringName:
	if current_form_mode == PLAYER_FORM_MODE_ARMED:
		return ARMED_ANIMATION_PREFIX

	return NORMAL_ANIMATION_PREFIX


func _update_facing(move_input: Vector2, shoot_input: Vector2) -> void:
	var facing_input := shoot_input if shoot_input != Vector2.ZERO else move_input
	if facing_input != Vector2.ZERO:
		facing_suffix = _vector_to_facing_suffix(facing_input)


func _vector_to_facing_suffix(direction: Vector2) -> StringName:
	if abs(direction.x) >= abs(direction.y):
		return &"right" if direction.x > 0.0 else &"left"

	return &"down" if direction.y > 0.0 else &"up"


func _on_shooting_timer_timeout() -> void:
	pass
