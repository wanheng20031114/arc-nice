extends YuanshiInsect
class_name YuanshiInsectAura

const AURA_RANGE_SEGMENTS := 48
const PLAYER_COLLISION_MASK := 2
const ENEMY_COLLISION_MASK := 4

@onready var aura_particles: GPUParticles2D = $AuraParticles
@onready var aura_range_fill: Polygon2D = $AuraRangeFill
@onready var aura_range_outline: Line2D = $AuraRangeOutline
@onready var aura_area: Area2D = $AuraArea
@onready var aura_area_shape: CollisionShape2D = $AuraArea/CollisionShape2D

# 毒性/守护光环状态。
var aura_active: bool = false
var aura_touched_player: Player = null
var aura_damage_cooldown_left: float = 0.0
var aura_defended_enemies: Dictionary = {}


func _ready() -> void:
	super._ready()
	aura_area.body_entered.connect(_on_aura_area_body_entered)
	aura_area.body_exited.connect(_on_aura_area_body_exited)


func _physics_process(delta: float) -> void:
	_update_aura_damage(delta)
	super._physics_process(delta)


func _apply_config() -> void:
	super._apply_config()

	if config == null:
		return

	_apply_aura_config()


# 根据配置资源启用或禁用光环，同步粒子和碰撞参数。
func _apply_aura_config() -> void:
	var aura_config := config as YuanshiInsectAuraConfig
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


func _apply_aura_range_indicator(aura_config: YuanshiInsectAuraConfig) -> void:
	var range_points := PackedVector2Array()
	for point_index in range(AURA_RANGE_SEGMENTS):
		var angle := TAU * float(point_index) / float(AURA_RANGE_SEGMENTS)
		range_points.append(Vector2.RIGHT.rotated(angle) * aura_config.aura_radius)

	aura_range_fill.polygon = range_points
	aura_range_fill.color = aura_config.aura_fill_color
	aura_range_outline.points = range_points
	aura_range_outline.default_color = aura_config.aura_outline_color
	aura_range_outline.width = aura_config.aura_outline_width


# 启动光环的粒子效果和伤害/增益检测。
func _start_aura() -> void:
	if aura_active:
		return

	aura_active = true
	var aura_config := config as YuanshiInsectAuraConfig
	if aura_config != null and aura_config.aura_particles_enabled:
		aura_particles.restart()
		aura_particles.emitting = true
	else:
		aura_particles.emitting = false
	var show_range_indicator := (config as YuanshiInsectGuardianConfig) == null
	aura_range_fill.visible = show_range_indicator
	aura_range_outline.visible = show_range_indicator
	aura_area.visible = true
	aura_area.set_deferred("monitoring", true)
	aura_area_shape.set_deferred("disabled", false)


# 关闭光环，停止粒子和检测。
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
	if config as YuanshiInsectGuardianConfig != null:
		aura_area.collision_mask = ENEMY_COLLISION_MASK
	else:
		aura_area.collision_mask = PLAYER_COLLISION_MASK


# 光环区域检测到目标进入。
func _on_aura_area_body_entered(body: Node2D) -> void:
	if is_dead or not aura_active:
		return

	if config as YuanshiInsectGuardianConfig != null:
		_add_guardian_defense_to_enemy(body as Enemy)
		return

	var player := body as Player
	if player == null:
		return

	aura_touched_player = player
	_try_deal_aura_damage()


# 目标离开光环区域。
func _on_aura_area_body_exited(body: Node2D) -> void:
	if config as YuanshiInsectGuardianConfig != null:
		_remove_guardian_defense_from_enemy(body as Enemy)
		return

	if body == aura_touched_player:
		aura_touched_player = null


func _add_guardian_defense_to_enemy(enemy: Enemy) -> void:
	var guardian_config := config as YuanshiInsectGuardianConfig
	if guardian_config == null:
		return
	if enemy == null:
		return
	if enemy == self:
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
	var aura_config := config as YuanshiInsectGreenShellConfig
	if aura_config == null:
		return

	_apply_multiplayer_player_damage(
		aura_touched_player,
		config.attack_damage,
		_get_multiplayer_damage_source_id(int(Time.get_ticks_msec())),
		&"yuanshi_aura"
	)
	aura_damage_cooldown_left = aura_config.aura_damage_interval


func _die() -> void:
	if is_dead:
		return

	_stop_aura()
	super._die()
