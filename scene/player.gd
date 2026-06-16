extends CharacterBody2D

class_name Player

signal xirang_changed(total: int, added_amount: int)
signal health_changed(current: int, maximum: int)
signal attack_speed_changed(attacks_per_second: float)
signal dodge_changed(chance: float)
signal died

@export var move_speed: float = 120.0
@export var max_health: int = 5
@export var invincibility_duration: float = 1.0
@export var attack_damage: int = 1
@export var attack_method_name: String = "枪"

var current_health: int = 0
var current_xirang: int = 20000
var invincibility_time_left: float = 0.0
var is_dead: bool = false
var controls_locked: bool = false
var mouse_fire_held: bool = false
var mouse_viewport_position: Vector2 = Vector2.ZERO

@export var fire_interval: float = 0.18
@export var bullet_spawn_distance: float = 18.0
@export var footstep_interval: float = 0.28
@export var skill1_charge_duration: float = 18.0
@export var skill1_bomb_spawn_distance: float = 18.0

@onready var body_sprite: AnimatedSprite2D = $BodySprite
@onready var armed_effect_sprite: AnimatedSprite2D = $ArmedEffectSprite
@onready var shooting_timer: Timer = $ShootingTimer
@onready var gunshot_audio: AudioStreamPlayer2D = $GunshotAudio
@onready var gunload_audio: AudioStreamPlayer2D = $GunloadAudio
@onready var footstep_audio: AudioStreamPlayer2D = $FootstepAudio
@onready var death_audio: AudioStreamPlayer2D = $DeathAudio
@onready var powerup_audio: AudioStreamPlayer2D = $PowerupAudio
@onready var secret_audio: AudioStreamPlayer2D = $SecretAudio
@onready var xirang_pickup_audio: AudioStreamPlayer2D = $XirangPickupAudio
@onready var health_bar: Control = $HealthBar
@onready var skill1_charge_bar: Skill1ChargeBar = $Skill1ChargeBar

const BULLET_SCENE := preload("res://scene/bullet.tscn")
const SKILL1_BOMB_SCENE := preload("res://scene/weishidaier_skill1_bomb.tscn")
const NORMAL_ANIMATION_PREFIX := &"normal"
const ARMED_ANIMATION_PREFIX := &"armed"
const DEFAULT_FIRE_RATE_MULTIPLIER := 1.0
const DEFAULT_MOVE_SPEED_MULTIPLIER := 1.0
const SPIRAL_PHASE_STEP := PI / 12
	
const BLINK_ENABLED_SHADER_PARAMETER := &"blink_enabled"

var facing_suffix: StringName = &"right"

# 当前移动倍率，由道具效果驱动。
var current_move_speed_multiplier: float = DEFAULT_MOVE_SPEED_MULTIPLIER
# 当前射速道具提供的射速倍率。
var rapid_fire_rate_multiplier: float = DEFAULT_FIRE_RATE_MULTIPLIER
# 形态道具提供的专属射速倍率，例如螺旋强化形态。
var form_fire_rate_multiplier: float = DEFAULT_FIRE_RATE_MULTIPLIER
# 当前玩家形态，决定使用 normal 还是 armed 动画。
var current_form_mode: int = PickupConfig.PlayerFormMode.NORMAL
# 当前弹幕模式，决定普通射击还是螺旋弹幕。
var current_shot_pattern: int = PickupConfig.ShotPattern.NORMAL

# 三类 Buff 分别维护剩余持续时间，避免互相覆盖。
var speed_buff_time_left: float = 0.0
var rapid_buff_time_left: float = 0.0
var form_buff_time_left: float = 0.0
# 螺旋弹幕的相位，用来让连续射击形成旋转感。
var spiral_phase: float = 0.0
var footstep_time_left: float = 0.0
var dodge_chance: float = 0.0
var skill1_unlocked: bool = false
var skill1_charge: float = 0.0
var last_attack_direction: Vector2 = Vector2.RIGHT


# 节点首次进入场景树时的初始化逻辑
func _ready() -> void:
	current_health = maxi(max_health, 1)
	shooting_timer.one_shot = true
	shooting_timer.wait_time = _get_effective_fire_interval()
	_set_hurt_blink_enabled(false)
	health_bar.setup(max_health, current_health)
	health_changed.emit(current_health, max_health)
	_update_animation()
	_update_armed_effect()
	_update_skill1_charge_bar()
	get_window().focus_exited.connect(_on_window_focus_exited)


func _input(event: InputEvent) -> void:
	var mouse_motion := event as InputEventMouseMotion
	if mouse_motion != null:
		mouse_viewport_position = mouse_motion.position
		return

	var mouse_event := event as InputEventMouseButton
	if mouse_event == null:
		return
	mouse_viewport_position = mouse_event.position
	if mouse_event.button_index == MOUSE_BUTTON_LEFT and not mouse_event.pressed:
		mouse_fire_held = false


func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed("skill1"):
		if _try_use_skill1():
			get_viewport().set_input_as_handled()
		return

	var mouse_event := event as InputEventMouseButton
	if mouse_event == null or mouse_event.button_index != MOUSE_BUTTON_LEFT:
		return

	mouse_fire_held = mouse_event.pressed and not controls_locked and not is_dead
	if mouse_fire_held:
		get_viewport().set_input_as_handled()


# 物理帧更新，处理玩家移动、射击和无敌/增益状态更新
func _physics_process(delta: float) -> void:
	_update_invincibility(delta)
	_update_pickup_effects(delta)
	_update_skill1_charge(delta)
	
	if is_dead:
		velocity = Vector2.ZERO
		return

	if controls_locked:
		velocity = Vector2.ZERO
		_update_footstep_audio(delta, Vector2.ZERO)
		_update_animation()
		_update_armed_effect()
		return
	
	var move_input := Input.get_vector("move_left", "move_right", "move_up", "move_down")
	var shoot_input := Input.get_vector("shoot_left", "shoot_right", "shoot_up", "shoot_down")
	if mouse_fire_held:
		shoot_input = _get_mouse_shoot_direction()

	velocity = move_input * _get_effective_move_speed()
	move_and_slide()
	_update_footstep_audio(delta, move_input)

	if current_shot_pattern == PickupConfig.ShotPattern.SPIRAL:
		_try_auto_spiral_shoot()
	elif shoot_input != Vector2.ZERO:
		_try_shoot(shoot_input)

	_update_facing(move_input, shoot_input)
	_update_animation()
	_update_armed_effect()


# 根据玩家当前形态和朝向更新基础动画序列
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


# 尝试进行一次常规射击
func _try_shoot(shoot_input: Vector2) -> void:
	if not shooting_timer.is_stopped():
		return

	var shoot_direction := shoot_input.normalized()
	var has_spawned_bullet := _fire_bullets(shoot_direction)

	if has_spawned_bullet:
		shooting_timer.start(_get_effective_fire_interval())

# 应用道具效果，更新玩家形态、射速、移速等增益状态
func apply_pickup(config: PickupConfig) -> bool:
	if config == null:
		return false
		
	var applied := false
	var should_refresh_shooting_timer := false
	var buff_duration := maxf(config.duration, 0.0)
	var has_form_override := (
		config.player_form_mode != PickupConfig.PlayerFormMode.NORMAL
		or config.shot_pattern != PickupConfig.ShotPattern.NORMAL
	)

	var has_fire_rate_override := not is_equal_approx(
		config.fire_rate_multiplier,
		DEFAULT_FIRE_RATE_MULTIPLIER
	)

	if not is_equal_approx(config.move_speed_multiplier, DEFAULT_MOVE_SPEED_MULTIPLIER):
		current_move_speed_multiplier = config.move_speed_multiplier
		speed_buff_time_left = buff_duration
		applied = true

	if config.heal_amount > 0:
		applied = _try_heal(config.heal_amount) or applied

	# 普通射速道具与形态专属射速提升维护，避免螺旋形态的射速被其他 Buff 状态覆盖。
	if has_fire_rate_override and not has_form_override:
		rapid_fire_rate_multiplier = config.fire_rate_multiplier
		rapid_buff_time_left = buff_duration
		should_refresh_shooting_timer = true
		applied = true
	if has_form_override:
		current_form_mode = config.player_form_mode
		current_shot_pattern = config.shot_pattern
		form_fire_rate_multiplier = (
			config.fire_rate_multiplier if has_fire_rate_override else DEFAULT_FIRE_RATE_MULTIPLIER
	)
		form_buff_time_left = buff_duration
		spiral_phase = 0.0
		should_refresh_shooting_timer = true
		applied = true

	if should_refresh_shooting_timer:
		_refresh_shooting_timer_wait_time()
	if applied:
		_play_pickup_audio(config, has_form_override)
	return applied
	
# 敌人或其他伤害来源统一通过这个入口让玩家受伤。
func apply_damage(amount: int) -> bool:
	if is_dead:
		return false

	if amount <= 0:
		return false

	if invincibility_time_left > 0.0:
		return false

	if dodge_chance > 0.0 and randf() < dodge_chance:
		_start_invincibility()
		return false

	current_health = maxi(current_health - amount, 0)
	health_bar.set_health(current_health, max_health)
	health_changed.emit(current_health, max_health)
	if current_health <= 0:
		_die()
		return true

	_start_invincibility()
	return true
	
# 获取当前生命值
func get_current_health() -> int:
	return current_health


func get_attacks_per_second() -> float:
	return 1.0 / _get_effective_fire_interval()


func set_controls_locked(locked: bool) -> void:
	controls_locked = locked
	if controls_locked:
		mouse_fire_held = false
		velocity = Vector2.ZERO
		footstep_audio.stop()


func get_xirang() -> int:
	return current_xirang


func add_xirang(amount: int) -> bool:
	if is_dead:
		return false
	if amount <= 0:
		return false

	current_xirang += amount
	xirang_changed.emit(current_xirang, amount)
	xirang_pickup_audio.pitch_scale = randf_range(1.12, 1.26)
	xirang_pickup_audio.play()
	return true


func has_skill1() -> bool:
	return skill1_unlocked


func try_purchase_skill1(cost: int) -> bool:
	if skill1_unlocked:
		return false
	if cost < 0:
		return false
	if current_xirang < cost:
		return false

	current_xirang -= cost
	xirang_changed.emit(current_xirang, -cost)
	unlock_skill1()
	return true


func unlock_skill1() -> bool:
	if skill1_unlocked:
		return false
	skill1_unlocked = true
	skill1_charge = 0.0
	_update_skill1_charge_bar()
	gunload_audio.play()
	return true


func _try_heal(amount: int) -> bool:
	if is_dead:
		return false
	if amount <= 0:
		return false
	if current_health >= max_health:
		return false

	current_health = mini(current_health + amount, max_health)
	health_bar.set_health(current_health, max_health)
	health_changed.emit(current_health, max_health)
	return true
	
# 根据射击模式和方向发射子弹，返回是否成功发射
func _fire_bullets(base_direction: Vector2) -> bool:
	if current_shot_pattern == PickupConfig.ShotPattern.SPIRAL:
		if base_direction != Vector2.ZERO:
			last_attack_direction = base_direction.normalized()
		var has_spawned_forward_bullet := _spawn_bullet(base_direction, false)
		var has_spawned_backward_bullet := _spawn_bullet(base_direction.rotated(PI), false)
		spiral_phase = wrapf(spiral_phase + SPIRAL_PHASE_STEP, 0.0, TAU)
		return has_spawned_forward_bullet or has_spawned_backward_bullet

	return _spawn_bullet(base_direction)


# 在指定方向上生成单颗子弹
func _spawn_bullet(shoot_direction: Vector2, track_attack_direction: bool = true) -> bool:
	var bullet := BULLET_SCENE.instantiate() as Bullet
	if bullet == null:
		return false

	var spawn_parent := get_tree().current_scene
	if spawn_parent == null:
		return false

	bullet.top_level = true
	bullet.setup(shoot_direction, attack_damage)
	spawn_parent.add_child(bullet)
	bullet.global_position = global_position + shoot_direction * bullet_spawn_distance
	if track_attack_direction and shoot_direction != Vector2.ZERO:
		last_attack_direction = shoot_direction.normalized()
	gunshot_audio.play()
	return true


# 螺旋射击模式下，自动根据相位角度发射子弹
func _try_auto_spiral_shoot() -> void:
	if not shooting_timer.is_stopped():
		return

	var spiral_direction := Vector2.RIGHT.rotated(spiral_phase)
	var has_spawned_bullet := _fire_bullets(spiral_direction)

	if has_spawned_bullet:
		shooting_timer.start(_get_effective_fire_interval())


func _update_skill1_charge(delta: float) -> void:
	if not skill1_unlocked:
		return
	if is_dead:
		return
	if skill1_charge >= skill1_charge_duration:
		return

	skill1_charge = minf(skill1_charge + delta, skill1_charge_duration)
	_update_skill1_charge_bar()


func _try_use_skill1() -> bool:
	if not skill1_unlocked:
		return false
	if is_dead or controls_locked:
		return false
	if skill1_charge < skill1_charge_duration:
		return false

	var bomb := SKILL1_BOMB_SCENE.instantiate() as WeishidaierSkill1Bomb
	if bomb == null:
		return false

	var spawn_parent := get_tree().current_scene
	if spawn_parent == null:
		return false

	var shoot_direction := _get_skill1_direction()
	bomb.top_level = true
	bomb.setup(self, shoot_direction, floori(float(attack_damage) * 3.3))
	spawn_parent.add_child(bomb)
	bomb.global_position = global_position + shoot_direction * skill1_bomb_spawn_distance
	skill1_charge = 0.0
	_update_skill1_charge_bar()
	gunload_audio.play()
	return true


func _update_skill1_charge_bar() -> void:
	if skill1_charge_bar == null:
		return
	skill1_charge_bar.set_unlocked(skill1_unlocked)
	skill1_charge_bar.set_charge(
		skill1_charge,
		skill1_charge_duration,
		skill1_unlocked and skill1_charge >= skill1_charge_duration
	)


func _get_skill1_direction() -> Vector2:
	if last_attack_direction != Vector2.ZERO:
		return last_attack_direction.normalized()
	return _facing_suffix_to_vector(facing_suffix)

# 获取当前实际移动速度（受移速加成影响）
func _get_effective_move_speed() -> float:
	return move_speed * current_move_speed_multiplier


func _get_mouse_shoot_direction() -> Vector2:
	var mouse_world_position := get_canvas_transform().affine_inverse() * mouse_viewport_position
	return global_position.direction_to(mouse_world_position)


func _on_window_focus_exited() -> void:
	mouse_fire_held = false


# 获取当前实际射击间隔（受射速加成影响）
func _get_effective_fire_interval() -> float:
	return max(fire_interval / _get_effective_fire_rate_multiplier(), 0.01)


# 获取当前实际射速倍率
func _get_effective_fire_rate_multiplier() -> float:
	if _has_active_form_override():
		return max(form_fire_rate_multiplier, 0.01)

	return max(rapid_fire_rate_multiplier, 0.01)


# 判断是否处于特殊的形态或弹幕模式下
func _has_active_form_override() -> bool:
	return (
		current_form_mode != PickupConfig.PlayerFormMode.NORMAL
		or current_shot_pattern != PickupConfig.ShotPattern.NORMAL
	)

# 刷新射击定时器的等待时间，响应射速 buff 变化
func _refresh_shooting_timer_wait_time() -> void:
	var new_interval := _get_effective_fire_interval()
	shooting_timer.wait_time = new_interval
	attack_speed_changed.emit(1.0 / new_interval)
	
	if shooting_timer.is_stopped():
		return
	if shooting_timer.time_left <= new_interval:
		return
		
	shooting_timer.start(new_interval)

# 每帧更新道具 Buff 剩余时间，并在到期后恢复默认状态。
func _update_pickup_effects(delta: float) -> void:
	if speed_buff_time_left > 0.0:
		speed_buff_time_left = maxf(speed_buff_time_left - delta, 0.0)
		if speed_buff_time_left <= 0.0:
			current_move_speed_multiplier = DEFAULT_MOVE_SPEED_MULTIPLIER

	if rapid_buff_time_left > 0.0:
		rapid_buff_time_left = maxf(rapid_buff_time_left - delta, 0.0)
		if rapid_buff_time_left <= 0.0:
			rapid_fire_rate_multiplier = DEFAULT_FIRE_RATE_MULTIPLIER
			_refresh_shooting_timer_wait_time()

	if form_buff_time_left > 0.0:
		form_buff_time_left = maxf(form_buff_time_left - delta, 0.0)
		if form_buff_time_left <= 0.0:
			current_form_mode = PickupConfig.PlayerFormMode.NORMAL
			current_shot_pattern = PickupConfig.ShotPattern.NORMAL
			form_fire_rate_multiplier = DEFAULT_FIRE_RATE_MULTIPLIER
			spiral_phase = 0.0
			_refresh_shooting_timer_wait_time()

# 更新武装状态特效动画表现
func _update_armed_effect() -> void:
	var is_armed := current_form_mode == PickupConfig.PlayerFormMode.ARMED

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


# 处理移动脚步声播放及间隔控制
func _update_footstep_audio(delta: float, move_input: Vector2) -> void:
	footstep_time_left = maxf(footstep_time_left - delta, 0.0)
	if move_input == Vector2.ZERO:
		footstep_time_left = 0.0
		return
	if footstep_time_left > 0.0:
		return

	footstep_audio.play()
	footstep_time_left = maxf(footstep_interval, 0.05)


# 播放道具拾取和形态加载的音效
func _play_pickup_audio(config: PickupConfig, has_form_override: bool) -> void:
	if config.pickup_type == PickupConfig.PickupType.TENPURA:
		secret_audio.play()
	else:
		powerup_audio.play()

	if has_form_override:
		gunload_audio.play()


# 根据当前形态获取动画前缀
func _get_animation_prefix() -> StringName:
	if current_form_mode == PickupConfig.PlayerFormMode.ARMED:
		return ARMED_ANIMATION_PREFIX

	return NORMAL_ANIMATION_PREFIX


# 根据移动和射击输入方向决定玩家角色的朝向更新
func _update_facing(move_input: Vector2, shoot_input: Vector2) -> void:
	var facing_input := shoot_input if shoot_input != Vector2.ZERO else move_input
	if facing_input != Vector2.ZERO:
		facing_suffix = _vector_to_facing_suffix(facing_input)


# 将向量方向映射为预期的字符串后缀名（用于动画）
func _vector_to_facing_suffix(direction: Vector2) -> StringName:
	if abs(direction.x) >= abs(direction.y):
		return &"right" if direction.x > 0.0 else &"left"

	return &"down" if direction.y > 0.0 else &"up"


func _facing_suffix_to_vector(suffix: StringName) -> Vector2:
	match suffix:
		&"left":
			return Vector2.LEFT
		&"up":
			return Vector2.UP
		&"down":
			return Vector2.DOWN
		_:
			return Vector2.RIGHT

# 更新受击后的无敌状态计时
func _update_invincibility(delta: float) -> void:
	if invincibility_time_left <= 0.0:
		return

	invincibility_time_left = maxf(invincibility_time_left - delta, 0.0)
	if invincibility_time_left > 0.0:
		return
	
	_set_hurt_blink_enabled(false)


# 开启玩家受伤后的无敌闪烁状态。
func _start_invincibility() -> void:
	invincibility_time_left = maxf(invincibility_duration, 0.0)
	_set_hurt_blink_enabled(invincibility_time_left > 0.0)


# 统一设置玩家受击闪烁开关，便于后续与其他表现逻辑解耦。
func _set_hurt_blink_enabled(enabled: bool) -> void:
	var sprite_material := body_sprite.material as ShaderMaterial
	if sprite_material != null:
		sprite_material.set_shader_parameter(BLINK_ENABLED_SHADER_PARAMETER, enabled)


# 玩家生命值归零时进入死亡状态。
func _die() -> void:
	is_dead = true
	mouse_fire_held = false
	velocity = Vector2.ZERO
	invincibility_time_left = 0.0
	_set_hurt_blink_enabled(false)
	shooting_timer.stop()
	armed_effect_sprite.visible = false
	armed_effect_sprite.stop()
	footstep_audio.stop()
	death_audio.play()
	# 玩家死亡时将血条归零并隐藏
	health_bar.set_health(0, max_health)
	health_bar.visible = false
	if body_sprite.sprite_frames != null and body_sprite.sprite_frames.has_animation(&"death"):
		body_sprite.play(&"death")
	died.emit()


func _on_shooting_timer_timeout() -> void:
	pass


# 升级基础攻击力，每级 +1
func upgrade_attack() -> void:
	attack_damage += 1


# 升级生命值上限，每级 +2，并同步回满当前生命
func upgrade_max_health() -> void:
	max_health += 2
	current_health = max_health
	health_bar.set_health(current_health, max_health)
	health_changed.emit(current_health, max_health)


# 升级攻击速度，每级攻击间隔减少 8%
func upgrade_attack_speed() -> void:
	fire_interval *= 0.92
	_refresh_shooting_timer_wait_time()


# 升级闪避能力，每级闪避率 +4%
func upgrade_dodge() -> void:
	dodge_chance = minf(dodge_chance + 0.04, 1.0)
	dodge_changed.emit(dodge_chance)
