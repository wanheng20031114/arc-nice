extends Player
class_name PlayerWeishidaier

const BULLET_SCENE := preload("res://scene/bullet.tscn")
const SKILL1_BOMB_SCENE := preload(
	"res://scene/player/weishidaier/weishidaier_skill1_bomb.tscn"
)
const ARMED_ANIMATION_PREFIX := &"armed"
const SPIRAL_PHASE_STEP := PI / 12.0

@export_group("Ammunition")
@export_range(1, 9999, 1, "or_greater") var ammo_capacity: int = 30
@export_range(0.01, 30.0, 0.01, "or_greater") var reload_duration: float = 1.5
@export_range(0.0, 100.0, 0.1) var ammo_free_shot_chance_percent: float = 0.0

@export_group("Projectile")
@export_range(0.0, 256.0, 0.1, "or_greater") var bullet_spawn_distance: float = 12.0
@export_range(0.0, 256.0, 0.1, "or_greater") var skill1_bomb_spawn_distance: float = 18.0

@onready var armed_effect_sprite: AnimatedSprite2D = $ArmedEffectSprite
@onready var ammo_bar: PlayerAmmoBar = $AmmoBar
@onready var primary_attack_audio: AudioStreamPlayer2D = $PrimaryAttackAudio
@onready var reload_audio: AudioStreamPlayer2D = $ReloadAudio

var current_ammo: int = 0
var is_reloading: bool = false
var reload_progress: float = 0.0

var form_fire_rate_multiplier: float = DEFAULT_FIRE_RATE_MULTIPLIER
var current_form_mode: int = PickupConfig.PlayerFormMode.NORMAL
var current_shot_pattern: int = PickupConfig.ShotPattern.NORMAL
var form_buff_time_left: float = 0.0
var spiral_phase: float = 0.0

var _armed_effect_sprite_base_position: Vector2 = Vector2.ZERO
var _ammo_bar_base_position: Vector2 = Vector2.ZERO


func _init() -> void:
	character_id = &"weishidaier"


func uses_ammunition() -> bool:
	return true


func supports_projectile_attack_patterns() -> bool:
	return true


func _initialize_character_resources() -> void:
	_reset_ammo_to_full()


func _update_character_resources(delta: float) -> void:
	_update_reload(delta)


func _reset_character_resources_on_revive() -> void:
	_reset_ammo_to_full()


func _cleanup_character_combat_on_death() -> void:
	if armed_effect_sprite != null:
		armed_effect_sprite.hide()
		armed_effect_sprite.stop()
	_update_ammo_bar()


func _update_character_visual_state() -> void:
	_update_armed_effect()


func _handle_primary_attack_input(shoot_input: Vector2) -> void:
	if current_shot_pattern == PickupConfig.ShotPattern.SPIRAL:
		_try_auto_spiral_shoot()
		return
	super._handle_primary_attack_input(shoot_input)


func _perform_primary_attack(attack_direction: Vector2) -> bool:
	return _fire_bullets(attack_direction)


func _can_perform_primary_attack() -> bool:
	return _can_fire_ammo_consuming_shot()


func _consume_primary_attack_resource() -> void:
	_consume_ammo_after_successful_shot()


func _apply_character_pickup(config: PickupConfig, buff_duration: float) -> bool:
	var has_fire_rate_override := not is_equal_approx(
		config.fire_rate_multiplier,
		DEFAULT_FIRE_RATE_MULTIPLIER
	)
	current_form_mode = config.player_form_mode
	current_shot_pattern = config.shot_pattern
	form_fire_rate_multiplier = (
		config.fire_rate_multiplier
		if has_fire_rate_override
		else DEFAULT_FIRE_RATE_MULTIPLIER
	)
	form_buff_time_left = buff_duration
	spiral_phase = 0.0
	return true


func _update_character_pickup_effects(delta: float) -> void:
	if form_buff_time_left <= 0.0:
		return
	form_buff_time_left = maxf(form_buff_time_left - delta, 0.0)
	if form_buff_time_left > 0.0:
		return
	current_form_mode = PickupConfig.PlayerFormMode.NORMAL
	current_shot_pattern = PickupConfig.ShotPattern.NORMAL
	form_fire_rate_multiplier = DEFAULT_FIRE_RATE_MULTIPLIER
	spiral_phase = 0.0
	_refresh_shooting_timer_wait_time()


func _get_character_fire_rate_multiplier() -> float:
	if _has_active_form_override():
		return maxf(form_fire_rate_multiplier, 0.01)
	return super._get_character_fire_rate_multiplier()


func _has_active_form_override() -> bool:
	return (
		current_form_mode != PickupConfig.PlayerFormMode.NORMAL
		or current_shot_pattern != PickupConfig.ShotPattern.NORMAL
	)


func get_ammo_capacity() -> int:
	return maxi(ammo_capacity, 1)


func get_reload_progress_ratio() -> float:
	return reload_progress if is_reloading else 0.0


func try_consume_authoritative_player_bullet_ammo() -> bool:
	if current_shot_pattern == PickupConfig.ShotPattern.SPIRAL:
		return true
	if not _can_fire_ammo_consuming_shot():
		return false
	_consume_ammo_after_successful_shot()
	return true


func apply_multiplayer_ammo_state(
	new_ammo_capacity: int,
	new_current_ammo: int,
	new_is_reloading: bool,
	new_reload_progress: float
) -> void:
	ammo_capacity = maxi(new_ammo_capacity, 1)
	current_ammo = clampi(new_current_ammo, 0, get_ammo_capacity())
	is_reloading = new_is_reloading
	reload_progress = clampf(new_reload_progress, 0.0, 1.0)
	_update_ammo_bar()


func _reset_ammo_to_full() -> void:
	current_ammo = get_ammo_capacity()
	is_reloading = false
	reload_progress = 0.0
	_update_ammo_bar()


func _can_fire_ammo_consuming_shot() -> bool:
	if current_shot_pattern == PickupConfig.ShotPattern.SPIRAL:
		return true
	if is_reloading:
		return false
	if current_ammo <= 0:
		_try_start_reload()
		return false
	return true


func _consume_ammo_after_successful_shot() -> void:
	if current_shot_pattern == PickupConfig.ShotPattern.SPIRAL:
		return
	if not _should_consume_ammo_for_shot():
		_update_ammo_bar()
		return
	current_ammo = maxi(current_ammo - 1, 0)
	if current_ammo <= 0:
		_try_start_reload()
	else:
		_update_ammo_bar()


func _should_consume_ammo_for_shot() -> bool:
	var free_chance := clampf(
		ammo_free_shot_chance_percent / 100.0 + _get_inventory_ammo_free_shot_chance(),
		0.0,
		1.0
	)
	if free_chance <= 0.0:
		return true
	if free_chance >= 1.0:
		return false
	return randf() >= free_chance


func _get_inventory_ammo_free_shot_chance() -> float:
	var total_chance := 0.0
	for item in _get_active_collectible_items():
		total_chance += item.ammo_free_shot_chance
	return clampf(total_chance, 0.0, 1.0)


func _try_start_reload() -> bool:
	if is_dead or controls_locked:
		return false
	if is_reloading:
		return false
	if current_ammo >= get_ammo_capacity():
		return false
	current_ammo = 0
	is_reloading = true
	reload_progress = 0.0
	_update_ammo_bar()
	_play_reload_audio()
	return true


func _update_reload(delta: float) -> void:
	if not is_reloading:
		return
	var safe_duration := maxf(reload_duration, 0.01)
	reload_progress = clampf(
		reload_progress + maxf(delta, 0.0) / safe_duration,
		0.0,
		1.0
	)
	if reload_progress >= 1.0:
		_complete_reload()
	else:
		_update_ammo_bar()


func _complete_reload() -> void:
	current_ammo = get_ammo_capacity()
	is_reloading = false
	reload_progress = 0.0
	_update_ammo_bar()


func _update_ammo_bar() -> void:
	if ammo_bar == null:
		return
	ammo_bar.visible = not is_dead
	if is_dead:
		return
	ammo_bar.set_ammo_state(
		current_ammo,
		get_ammo_capacity(),
		is_reloading,
		get_reload_progress_ratio()
	)


func _play_reload_audio() -> void:
	if reload_audio != null and reload_audio.stream != null:
		reload_audio.play()


func _fire_bullets(base_direction: Vector2) -> bool:
	if current_shot_pattern == PickupConfig.ShotPattern.SPIRAL:
		if base_direction != Vector2.ZERO:
			last_attack_direction = base_direction.normalized()
		var has_spawned_forward_bullet := _spawn_bullet(base_direction, false)
		var has_spawned_backward_bullet := _spawn_bullet(base_direction.rotated(PI), false)
		spiral_phase = wrapf(spiral_phase + SPIRAL_PHASE_STEP, 0.0, TAU)
		var has_spawned_bullet := (
			has_spawned_forward_bullet or has_spawned_backward_bullet
		)
		if has_spawned_bullet:
			notify_primary_attack_performed()
		return has_spawned_bullet

	var has_spawned_bullet := _spawn_bullet(base_direction)
	if has_spawned_bullet:
		notify_primary_attack_performed()
	return has_spawned_bullet


func _spawn_bullet(shoot_direction: Vector2, track_attack_direction: bool = true) -> bool:
	var spawn_parent := get_tree().current_scene
	if spawn_parent == null:
		return false
	var bullet := BULLET_SCENE.instantiate() as Bullet
	if bullet == null:
		return false

	bullet.top_level = true
	var pierces_enemies := _should_fire_piercing_bullet()
	var homing_target: Enemy = null
	if _should_fire_homing_bullet():
		homing_target = _find_homing_bullet_target(shoot_direction)
	var bullet_damage := get_outgoing_damage(
		attack_damage,
		EnemyConfig.DamageType.PHYSICAL
	)
	bullet.setup(shoot_direction, bullet_damage, pierces_enemies)
	bullet.setup_homing(homing_target)
	bullet.setup_collectible_owner(self)
	spawn_parent.add_child(bullet)
	bullet.global_position = global_position + shoot_direction * bullet_spawn_distance
	var target_enemy_net_id := 0
	if homing_target != null and is_instance_valid(homing_target):
		target_enemy_net_id = int(homing_target.get_meta("net_id", 0))
	_register_multiplayer_projectile(
		bullet,
		&"player_bullet",
		bullet.global_position,
		shoot_direction,
		bullet_damage,
		bullet.speed,
		bullet.max_lifetime,
		pierces_enemies,
		0,
		target_enemy_net_id
	)
	if track_attack_direction and shoot_direction != Vector2.ZERO:
		last_attack_direction = shoot_direction.normalized()
	if primary_attack_audio != null and primary_attack_audio.stream != null:
		primary_attack_audio.play()
	return true


func _try_auto_spiral_shoot() -> void:
	if not shooting_timer.is_stopped():
		return
	var spiral_direction := Vector2.RIGHT.rotated(spiral_phase)
	if _fire_bullets(spiral_direction):
		shooting_timer.start(_get_effective_fire_interval())


func _get_skill1_direction() -> Vector2:
	if last_attack_direction != Vector2.ZERO:
		return last_attack_direction.normalized()
	return _facing_suffix_to_vector(facing_suffix)


func _try_use_skill1() -> bool:
	if not skill1_unlocked:
		return false
	if is_dead or controls_locked:
		return false
	_sync_skill1_charge_duration_to_upgrade_level()
	if skill1_charge < skill1_charge_duration:
		return false

	var spawn_parent := get_tree().current_scene
	if spawn_parent == null:
		return false
	var bomb := SKILL1_BOMB_SCENE.instantiate() as WeishidaierSkill1Bomb
	if bomb == null:
		return false

	var shoot_direction := _get_skill1_direction()
	bomb.top_level = true
	var bomb_damage := get_skill1_projectile_damage()
	bomb.setup(self, shoot_direction, bomb_damage)
	if not try_begin_skill1_activation(_uses_authoritative_skill_preserve_roll()):
		bomb.free()
		return false
	spawn_parent.add_child(bomb)
	bomb.global_position = global_position + shoot_direction * skill1_bomb_spawn_distance
	_register_multiplayer_projectile(
		bomb,
		&"skill1_bomb",
		bomb.global_position,
		shoot_direction,
		bomb_damage,
		bomb.speed,
		bomb.max_lifetime
	)
	_activate_collectible_skill_effects()
	_play_reload_audio()
	return true


func get_skill1_projectile_damage() -> int:
	return get_outgoing_damage(
		floori(float(attack_damage) * 3.3),
		EnemyConfig.DamageType.PHYSICAL
	)


func can_request_multiplayer_projectile(projectile_type: StringName) -> bool:
	if is_dead or controls_locked:
		return false
	return projectile_type == &"player_bullet" or projectile_type == &"skill1_bomb"


func get_multiplayer_projectile_spawn_distance(projectile_type: StringName) -> float:
	match projectile_type:
		&"player_bullet":
			return bullet_spawn_distance
		&"skill1_bomb":
			return skill1_bomb_spawn_distance
		_:
			return 0.0


func _cache_character_visual_base_positions() -> void:
	_armed_effect_sprite_base_position = armed_effect_sprite.position
	_ammo_bar_base_position = ammo_bar.position


func _set_character_visual_offset(offset: Vector2) -> void:
	armed_effect_sprite.position = _armed_effect_sprite_base_position + offset
	ammo_bar.position = _ammo_bar_base_position + offset


func _apply_multiplayer_character_anim_state(anim_state: int) -> void:
	current_form_mode = (
		PickupConfig.PlayerFormMode.ARMED
		if anim_state == 1
		else PickupConfig.PlayerFormMode.NORMAL
	)


func _apply_multiplayer_character_realtime_state(
	new_form_mode: int,
	new_shot_pattern: int,
	new_ammo_capacity: int,
	new_current_ammo: int,
	new_is_reloading: bool,
	new_reload_progress: float
) -> void:
	if new_ammo_capacity > 0 and new_current_ammo >= 0:
		apply_multiplayer_ammo_state(
			new_ammo_capacity,
			new_current_ammo,
			new_is_reloading,
			new_reload_progress
		)
	current_form_mode = new_form_mode
	current_shot_pattern = new_shot_pattern
	form_buff_time_left = 0.0


func has_active_multiplayer_character_state() -> bool:
	return (
		current_form_mode != PickupConfig.PlayerFormMode.NORMAL
		or current_shot_pattern != PickupConfig.ShotPattern.NORMAL
		or is_reloading
	)


func get_multiplayer_form_mode() -> int:
	return current_form_mode


func get_multiplayer_shot_pattern() -> int:
	return current_shot_pattern


func get_multiplayer_ammo_capacity() -> int:
	return maxi(ammo_capacity, 1)


func get_multiplayer_current_ammo() -> int:
	return current_ammo


func get_multiplayer_is_reloading() -> bool:
	return is_reloading


func get_multiplayer_reload_progress() -> float:
	return reload_progress if is_reloading else 0.0


func _update_armed_effect() -> void:
	if is_dead or current_form_mode != PickupConfig.PlayerFormMode.ARMED:
		if armed_effect_sprite.visible:
			armed_effect_sprite.hide()
		if armed_effect_sprite.is_playing():
			armed_effect_sprite.stop()
		return
	armed_effect_sprite.show()
	if armed_effect_sprite.is_playing():
		return
	if (
		armed_effect_sprite.sprite_frames != null
		and armed_effect_sprite.sprite_frames.has_animation(&"default")
	):
		armed_effect_sprite.play(&"default")


func _get_animation_prefix() -> StringName:
	if current_form_mode == PickupConfig.PlayerFormMode.ARMED:
		return ARMED_ANIMATION_PREFIX
	return super._get_animation_prefix()


func get_multiplayer_anim_state() -> int:
	return 1 if current_form_mode == PickupConfig.PlayerFormMode.ARMED else 0


func _play_skill_progress_feedback() -> void:
	_play_reload_audio()


func _play_character_pickup_feedback() -> void:
	_play_reload_audio()
