extends Enemy
class_name YuanshiInsect

const PICKUP_SCENE := preload("res://scene/pickup.tscn")
const XIRANG_DROP_SCENE := preload("res://scene/xirang_drop.tscn")
const AURA_CONFIG_SCRIPT := preload(
	"res://resources/config/enemies/yuanshi_insect_aura_config.gd"
)
const GREEN_SHELL_CONFIG_SCRIPT := preload(
	"res://resources/config/enemies/yuanshi_insect_green_shell_config.gd"
)
const GUARDIAN_CONFIG_SCRIPT := preload(
	"res://resources/config/enemies/yuanshi_insect_guardian_config.gd"
)
const EXPLOSION_QUERY_MAX_RESULTS := 16
const MAX_XIRANG_ORBS_PER_ENEMY := 4
const AURA_RANGE_SEGMENTS := 48
const PLAYER_COLLISION_MASK := 2
const ENEMY_COLLISION_MASK := 4

# 寻路路径刷新间隔。多只敌人共享 GridPathfinder，但各自按这个节奏更新目标路径。
@export var path_refresh_interval: float = 0.25

# 距离当前路点小于该值时，切换到下一个路点。
@export var waypoint_arrival_distance: float = 6.0

# 足够接近玩家时直接追踪玩家当前位置，避免围绕玩家所在格子中心反复寻路。
@export var direct_chase_extra_distance: float = 2.0

@onready var explosion_area: Area2D = $ExplosionArea
@onready var explosion_shape: CollisionShape2D = $ExplosionArea/CollisionShape2D
@onready var explosion_audio: AudioStreamPlayer2D = $ExplosionAudio
@onready var aura_particles: GPUParticles2D = $AuraParticles
@onready var aura_range_fill: Polygon2D = $AuraRangeFill
@onready var aura_range_outline: Line2D = $AuraRangeOutline
@onready var aura_area: Area2D = $AuraArea
@onready var aura_area_shape: CollisionShape2D = $AuraArea/CollisionShape2D

# 敌人实例自己的随机数生成器，用于掉落判定。
var random_generator: RandomNumberGenerator = RandomNumberGenerator.new()
# 当前缓存路径，避免每帧重复计算 A*。
var current_path: PackedVector2Array = PackedVector2Array()
var current_path_index: int = 0
var path_refresh_time_left: float = 0.0

# 毒性光环状态。
var aura_active: bool = false
var aura_touched_player: Player = null
var aura_damage_cooldown_left: float = 0.0
var aura_defended_enemies: Dictionary = {}


# 初始化配置、信号和默认动画。
func _ready() -> void:
	super._ready()
	random_generator.randomize()
	aura_area.body_entered.connect(_on_aura_area_body_entered)
	aura_area.body_exited.connect(_on_aura_area_body_exited)


func _physics_process(delta: float) -> void:
	_update_hurt_blink(delta)
	_update_touch_damage(delta)
	_update_aura_damage(delta)

	if is_dead:
		velocity = Vector2.ZERO
		return

	if not is_instance_valid(target_player):
		velocity = Vector2.ZERO
		move_and_slide()
		return

	var move_direction := _get_navigation_move_direction(delta)
	_update_facing(move_direction)
	velocity = move_direction * _get_move_speed()
	move_and_slide()


func _apply_config() -> void:
	super._apply_config()

	if config == null:
		return

	_apply_explosion_radius(config.explosion_radius)
	_apply_aura_config()


# 将配置中的爆炸半径同步到一次性爆炸检测区。
func _apply_explosion_radius(radius: float) -> void:
	var explosion_circle_shape := explosion_shape.shape as CircleShape2D
	if explosion_circle_shape != null:
		explosion_circle_shape.radius = maxf(radius, 0.0)


# 根据配置资源启用或禁用毒性光环，同步粒子和碰撞参数。
func _apply_aura_config() -> void:
	var aura_config := config as AURA_CONFIG_SCRIPT
	if aura_config == null or not aura_config.aura_enabled:
		_stop_aura()
		return

	var aura_circle := aura_area_shape.shape as CircleShape2D
	if aura_circle != null:
		aura_circle.radius = aura_config.aura_radius

	if aura_config.aura_particles_enabled:
		var aura_material := aura_particles.process_material as ParticleProcessMaterial
		if aura_material != null:
			var emission_radius := maxf(aura_config.aura_particle_emission_radius, 0.0)
			var emission_thickness := clampf(
				aura_config.aura_particle_emission_thickness,
				0.0,
				emission_radius
			)
			aura_material.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_RING
			aura_material.emission_ring_axis = Vector3.BACK
			aura_material.emission_ring_height = 0.0
			aura_material.emission_ring_radius = emission_radius
			aura_material.emission_ring_inner_radius = emission_radius - emission_thickness
			aura_material.initial_velocity_min = 0.0
			aura_material.initial_velocity_max = 0.0
			aura_material.radial_velocity_min = minf(
				aura_config.aura_particle_speed_min,
				aura_config.aura_particle_speed_max
			)
			aura_material.radial_velocity_max = maxf(
				aura_config.aura_particle_speed_min,
				aura_config.aura_particle_speed_max
			)
			aura_material.scale_min = minf(
				aura_config.aura_particle_scale_min,
				aura_config.aura_particle_scale_max
			)
			aura_material.scale_max = maxf(
				aura_config.aura_particle_scale_min,
				aura_config.aura_particle_scale_max
			)
			aura_material.color = aura_config.aura_particle_color
			aura_material.color_initial_ramp = aura_config.aura_particle_color_ramp

		aura_particles.amount = maxi(aura_config.aura_particle_amount, 1)
		aura_particles.lifetime = maxf(aura_config.aura_particle_lifetime, 0.05)
		aura_particles.preprocess = aura_particles.lifetime
		aura_particles.texture = aura_config.aura_particle_texture
	else:
		aura_particles.emitting = false
	var visibility_radius := aura_config.aura_radius + 16.0
	aura_particles.visibility_rect = Rect2(
		Vector2.ONE * -visibility_radius,
		Vector2.ONE * visibility_radius * 2.0
	)
	_apply_aura_range_indicator(aura_config)
	_configure_aura_collision_mask()

	_start_aura()


func _apply_aura_range_indicator(aura_config: AURA_CONFIG_SCRIPT) -> void:
	var range_points := PackedVector2Array()
	for point_index in range(AURA_RANGE_SEGMENTS):
		var angle := TAU * float(point_index) / float(AURA_RANGE_SEGMENTS)
		range_points.append(Vector2.RIGHT.rotated(angle) * aura_config.aura_radius)

	aura_range_fill.polygon = range_points
	aura_range_fill.color = aura_config.aura_fill_color
	aura_range_outline.points = range_points
	aura_range_outline.default_color = aura_config.aura_outline_color
	aura_range_outline.width = aura_config.aura_outline_width


# 启动毒性光环的粒子效果和伤害检测。
func _start_aura() -> void:
	if aura_active:
		return

	aura_active = true
	if config as GUARDIAN_CONFIG_SCRIPT != null:
		_add_guardian_defense_to_enemy(self)
	var aura_config := config as AURA_CONFIG_SCRIPT
	if aura_config != null and aura_config.aura_particles_enabled:
		aura_particles.restart()
		aura_particles.emitting = true
	else:
		aura_particles.emitting = false
	aura_range_fill.visible = true
	aura_range_outline.visible = true
	aura_area.visible = true
	aura_area.set_deferred("monitoring", true)
	aura_area_shape.set_deferred("disabled", false)


# 关闭毒性光环，停止粒子和伤害检测。
func _stop_aura() -> void:
	aura_active = false
	_clear_guardian_defense_modifiers()
	aura_particles.emitting = false
	aura_range_fill.visible = false
	aura_range_outline.visible = false
	aura_area.visible = false
	aura_area.set_deferred("monitoring", false)
	aura_area_shape.set_deferred("disabled", true)
	aura_touched_player = null
	aura_damage_cooldown_left = 0.0


func _configure_aura_collision_mask() -> void:
	if config as GUARDIAN_CONFIG_SCRIPT != null:
		aura_area.collision_mask = ENEMY_COLLISION_MASK
	else:
		aura_area.collision_mask = PLAYER_COLLISION_MASK


# 光环区域检测到玩家进入。
func _on_aura_area_body_entered(body: Node2D) -> void:
	if is_dead or not aura_active:
		return

	if config as GUARDIAN_CONFIG_SCRIPT != null:
		_add_guardian_defense_to_enemy(body as Enemy)
		return

	var player := body as Player
	if player == null:
		return

	aura_touched_player = player
	_try_deal_aura_damage()


# 玩家离开光环区域。
func _on_aura_area_body_exited(body: Node2D) -> void:
	if config as GUARDIAN_CONFIG_SCRIPT != null:
		_remove_guardian_defense_from_enemy(body as Enemy)
		return

	if body == aura_touched_player:
		aura_touched_player = null


func _add_guardian_defense_to_enemy(enemy: Enemy) -> void:
	var guardian_config := config as GUARDIAN_CONFIG_SCRIPT
	if guardian_config == null:
		return
	if enemy == null:
		return
	if enemy.is_dead:
		return

	var enemy_id := enemy.get_instance_id()
	if aura_defended_enemies.has(enemy_id):
		return

	aura_defended_enemies[enemy_id] = enemy
	enemy.add_physical_defense_modifier(
		get_instance_id(),
		guardian_config.aura_physical_defense_bonus
	)


func _remove_guardian_defense_from_enemy(enemy: Enemy) -> void:
	if enemy == null:
		return

	var enemy_id := enemy.get_instance_id()
	if not aura_defended_enemies.has(enemy_id):
		return

	aura_defended_enemies.erase(enemy_id)
	enemy.remove_physical_defense_modifier(get_instance_id())


func _clear_guardian_defense_modifiers() -> void:
	for enemy in aura_defended_enemies.values():
		var defended_enemy := enemy as Enemy
		if is_instance_valid(defended_enemy):
			defended_enemy.remove_physical_defense_modifier(get_instance_id())
	aura_defended_enemies.clear()


# 每帧更新光环持续伤害冷却，在冷却结束后再次造成伤害。
func _update_aura_damage(delta: float) -> void:
	if not aura_active:
		return

	if aura_damage_cooldown_left > 0.0:
		aura_damage_cooldown_left = maxf(aura_damage_cooldown_left - delta, 0.0)

	if aura_touched_player == null:
		return
	if not is_instance_valid(aura_touched_player):
		aura_touched_player = null
		return
	if aura_damage_cooldown_left > 0.0:
		return

	_try_deal_aura_damage()


# 对光环范围内的玩家造成一次伤害并重置冷却。
func _try_deal_aura_damage() -> void:
	if aura_touched_player == null:
		return
	var aura_config := config as GREEN_SHELL_CONFIG_SCRIPT
	if aura_config == null:
		return

	aura_touched_player.apply_damage(config.attack_damage)
	aura_damage_cooldown_left = aura_config.aura_damage_interval


# 获取当前敌人的移动速度。
func _get_move_speed() -> float:
	if config == null:
		return 0.0
	return config.move_speed


func _get_navigation_move_direction(delta: float) -> Vector2:
	path_refresh_time_left = maxf(path_refresh_time_left - delta, 0.0)

	if _should_direct_chase_target():
		_clear_navigation_path()
		return global_position.direction_to(target_player.global_position)

	if pathfinder == null or not pathfinder.get("is_built"):
		return global_position.direction_to(target_player.global_position)

	if path_refresh_time_left <= 0.0 or current_path.is_empty():
		_refresh_navigation_path()

	if current_path.is_empty():
		return global_position.direction_to(target_player.global_position)

	while current_path_index < current_path.size():
		var waypoint := current_path[current_path_index]
		if global_position.distance_to(waypoint) > waypoint_arrival_distance:
			return global_position.direction_to(waypoint)
		current_path_index += 1

	return global_position.direction_to(target_player.global_position)


func _refresh_navigation_path() -> void:
	path_refresh_time_left = maxf(path_refresh_interval, 0.05)
	current_path = pathfinder.get_global_path(global_position, target_player.global_position)
	current_path_index = 0


func _clear_navigation_path() -> void:
	current_path = PackedVector2Array()
	current_path_index = 0
	path_refresh_time_left = 0.0


func _should_direct_chase_target() -> bool:
	var direct_chase_distance := _get_collision_radius() + _get_target_collision_radius() + direct_chase_extra_distance
	return global_position.distance_to(target_player.global_position) <= direct_chase_distance


func _get_collision_radius() -> float:
	var body_shape := collision_shape.shape as CircleShape2D
	if body_shape == null:
		return 0.0

	return body_shape.radius


func _get_target_collision_radius() -> float:
	var target_collision_shape := target_player.get_node_or_null("CollisionShape2D") as CollisionShape2D
	if target_collision_shape == null:
		return 0.0

	var target_circle_shape := target_collision_shape.shape as CircleShape2D
	if target_circle_shape == null:
		return 0.0

	return target_circle_shape.radius


# 根据水平移动方向更新贴图翻转，竖直移动时保留当前朝向。
func _update_facing(move_direction: Vector2) -> void:
	if is_zero_approx(move_direction.x):
		return

	animated_sprite.flip_h = move_direction.x < 0.0

	
# 进入死亡阶段后停止碰撞，并启动统一的死亡动画流程。
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
	_stop_aura()
	death_audio.play()
	call_deferred("_drop_xirang")
	_try_drop_pickup()
	_start_death_sequence()  

# 先播放通用死亡动画；自爆敌人在其播放结束后再进入爆炸阶段。
func _start_death_sequence() -> void:
	if config == null:
		queue_free()
		return

	if _play_death_sequence_animation(config.death_animation_name, DeathSequenceStage.DEATH):
		return

	_finish_after_death_animation()


# 普通敌人在死亡动画结束后直接销毁，自爆敌人则进入第二段爆炸流程。
func _finish_after_death_animation() -> void:
	if _should_play_explosion_sequence():
		_start_explosion_sequence()
		return

	queue_free()
	
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


# 统一切换死亡阶段动画，找不到动画时返回 false，由上层决定如何降级处理。
func _play_death_sequence_animation(animation_name: StringName, stage: Enemy.DeathSequenceStage) -> bool:
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


func _should_play_explosion_sequence() -> bool:
	return config != null and config.explode_on_death

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
			hit_player.apply_damage(config.explosion_damage)
			continue

		var hit_enemy := collider as Enemy
		if hit_enemy != null:
			hit_enemy.apply_damage(config.explosion_damage)

# 敌人死亡后按概率掉落一个随机道具。
func _try_drop_pickup() -> void:
	if config == null:
		return

	if config.pickup_drop_configs.is_empty():
		return

	if random_generator.randf() > config.pickup_drop_chance:
		return

	var pickup_config := _pick_pickup_drop_config()
	if pickup_config == null:
		return

	call_deferred("_spawn_dropped_pickup", pickup_config, global_position)

func _pick_pickup_drop_config() -> PickupConfig:
	if config == null:
		return null

	var available_pickup_configs: Array[PickupConfig] = []
	var total_weight := 0.0

	for pickup_config in config.pickup_drop_configs:
		if pickup_config == null:
			continue
		if pickup_config.drop_weight <= 0.0:
			continue

		available_pickup_configs.append(pickup_config)
		total_weight += pickup_config.drop_weight

	if available_pickup_configs.is_empty():
		return null
	if total_weight <= 0.0:
		return null

	var target_weight := random_generator.randf_range(0.0, total_weight)
	var accumulated_weight := 0.0

	for pickup_config in available_pickup_configs:
		accumulated_weight += pickup_config.drop_weight
		if target_weight <= accumulated_weight:
			return pickup_config

	return available_pickup_configs.back()

func _spawn_dropped_pickup(pickup_config: PickupConfig, spawn_position: Vector2) -> void:
	var drop_parent := get_parent()
	if drop_parent == null:
		return

	var pickup_instance := PICKUP_SCENE.instantiate() as Pickup
	if pickup_instance == null:
		return

	pickup_instance.config = pickup_config
	drop_parent.add_child(pickup_instance)
	pickup_instance.global_position = spawn_position


func _drop_xirang() -> void:
	if config == null:
		return
	if config.xirang_drop_amount <= 0:
		return
	if not is_instance_valid(target_player):
		return

	var drop_parent := get_parent()
	if drop_parent == null:
		return

	var orb_count := mini(config.xirang_drop_amount, MAX_XIRANG_ORBS_PER_ENEMY)
	var base_value := floori(float(config.xirang_drop_amount) / float(orb_count))
	var remainder := config.xirang_drop_amount % orb_count

	for orb_index in range(orb_count):
		var drop := XIRANG_DROP_SCENE.instantiate() as XirangDrop
		if drop == null:
			continue

		var orb_value := base_value + (1 if orb_index < remainder else 0)
		var angle := random_generator.randf_range(0.0, TAU)
		var distance := random_generator.randf_range(8.0, 18.0)
		var landing_offset := Vector2.RIGHT.rotated(angle) * distance
		drop_parent.add_child(drop)
		drop.setup(orb_value, target_player, global_position, landing_offset)


# 死亡动画播放完成后销毁敌人实例。
func _on_animated_sprite_animation_finished() -> void:
	if not is_dead:
		return

	if death_animation_name_in_use == &"":
		return

	if animated_sprite.animation != death_animation_name_in_use:
		return

	match death_sequence_stage:
		DeathSequenceStage.DEATH:
			_finish_after_death_animation()
		DeathSequenceStage.EXPLOSION:
			queue_free()
		_:
			queue_free()
