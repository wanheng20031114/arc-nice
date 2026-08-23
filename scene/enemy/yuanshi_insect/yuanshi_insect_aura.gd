extends YuanshiInsect
class_name YuanshiInsectAura

signal guardian_aura_deactivated(guardian: Enemy)

const AURA_RANGE_SEGMENTS := 24
const AURA_PARTICLE_FIXED_FPS := 30
const MAX_ACTIVE_GUARDIAN_EMISSION_BOOSTS := 12
const PLAYER_COLLISION_MASK := 2
const GUARDIAN_BASE_HALO_MODULATE := Color(0.2, 0.78, 1.0, 0.78)
const GUARDIAN_EMISSION_CANDIDATE_GROUP := &"guardian_emission_budget_candidates"
const GUARDIAN_EMISSION_ACTIVE_GROUP := &"guardian_emission_budget_active"

@onready var aura_particles: GPUParticles2D = get_node_or_null("AuraParticles") as GPUParticles2D
@onready var aura_range_outline: Line2D = get_node_or_null("AuraRangeOutline") as Line2D
@onready var aura_area: Area2D = get_node_or_null("AuraArea") as Area2D
@onready var aura_area_shape: CollisionShape2D = (
	get_node_or_null("AuraArea/CollisionShape2D") as CollisionShape2D
)
@onready var guardian_halo: Sprite2D = get_node_or_null("GuardianLightHalo") as Sprite2D
@onready var guardian_light_emission: Sprite2D = (
	get_node_or_null("GuardianLightEmission") as Sprite2D
)

# 毒性/守护光环状态。
var aura_active: bool = false
var aura_touched_player: Player = null
var aura_damage_cooldown_left: float = 0.0


func _ready() -> void:
	super._ready()
	if not tree_entered.is_connected(_on_guardian_tree_entered):
		tree_entered.connect(_on_guardian_tree_entered)
	if not visibility_changed.is_connected(_on_guardian_visibility_changed):
		visibility_changed.connect(_on_guardian_visibility_changed)
	_configure_guardian_emission_budget()


func _exit_tree() -> void:
	_release_guardian_emission_budget()
	super._exit_tree()


func _physics_process(delta: float) -> void:
	_update_aura_damage(delta)
	super._physics_process(delta)


func supports_centralized_authoritative_simulation() -> bool:
	return false


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
	if _uses_centralized_guardian_aura():
		# GuardianAuraSystem owns guardian range queries and defense sources. The
		# guardian scene intentionally has no per-instance particle/range/Area nodes.
		_start_aura()
		return
	if not _has_local_damage_aura_nodes():
		push_error(
			"Green-shell aura scenes require AuraParticles, AuraRangeOutline, "
			+ "AuraArea and AuraArea/CollisionShape2D."
		)
		aura_active = false
		return

	_apply_local_damage_aura_config(aura_config)
	_start_aura()


func _apply_local_damage_aura_config(aura_config: YuanshiInsectAuraConfig) -> void:

	var aura_circle := aura_area_shape.shape as CircleShape2D
	if aura_circle != null:
		aura_circle.radius = aura_config.aura_radius

	if aura_config.aura_particles_enabled:
		aura_particles.process_mode = Node.PROCESS_MODE_INHERIT
		aura_particles.visible = true
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
		# Preprocessing every newly spawned aura caused a large one-frame GPU setup
		# spike. Let the ring fill naturally during its first lifetime instead.
		aura_particles.preprocess = 0.0
		aura_particles.fixed_fps = AURA_PARTICLE_FIXED_FPS
		aura_particles.texture = aura_config.aura_particle_texture
	else:
		aura_particles.emitting = false
		aura_particles.visible = false
		aura_particles.process_mode = Node.PROCESS_MODE_DISABLED

	var visibility_radius := aura_config.aura_radius + 16.0
	aura_particles.visibility_rect = Rect2(
		Vector2.ONE * -visibility_radius,
		Vector2.ONE * visibility_radius * 2.0
	)
	_apply_aura_range_indicator(aura_config)
	_configure_aura_collision_mask()
	_ensure_player_aura_signals_connected()


func _has_local_damage_aura_nodes() -> bool:
	return (
		aura_particles != null
		and aura_range_outline != null
		and aura_area != null
		and aura_area_shape != null
	)


func _uses_centralized_guardian_aura() -> bool:
	return config as YuanshiInsectGuardianConfig != null


func _apply_aura_range_indicator(aura_config: YuanshiInsectAuraConfig) -> void:
	var range_points := PackedVector2Array()
	for point_index in range(AURA_RANGE_SEGMENTS):
		var angle := TAU * float(point_index) / float(AURA_RANGE_SEGMENTS)
		range_points.append(Vector2.RIGHT.rotated(angle) * aura_config.aura_radius)

	aura_range_outline.points = range_points
	aura_range_outline.default_color = aura_config.aura_outline_color
	aura_range_outline.width = aura_config.aura_outline_width


# 启动光环的粒子效果和伤害/增益检测。
func _start_aura() -> void:
	if aura_active:
		return

	aura_active = true
	if _uses_centralized_guardian_aura():
		return

	var aura_config := config as YuanshiInsectAuraConfig
	if aura_config != null and aura_config.aura_particles_enabled:
		aura_particles.process_mode = Node.PROCESS_MODE_INHERIT
		aura_particles.visible = true
		aura_particles.restart()
		aura_particles.emitting = true
	else:
		aura_particles.emitting = false
	aura_range_outline.visible = true
	# 绿壳仍使用原生 Area2D 对玩家造成周期伤害。
	aura_area.visible = true
	aura_area.set_deferred("monitoring", true)
	aura_area.set_deferred("monitorable", true)
	aura_area_shape.set_deferred("disabled", false)


# 关闭光环，停止粒子和检测。
func _stop_aura() -> void:
	var guardian_aura := _uses_centralized_guardian_aura()
	var guardian_was_active := aura_active and guardian_aura
	aura_active = false
	if guardian_was_active:
		guardian_aura_deactivated.emit(self)
	if guardian_aura:
		aura_touched_player = null
		aura_damage_cooldown_left = 0.0
		return

	aura_particles.emitting = false
	aura_particles.visible = false
	aura_particles.process_mode = Node.PROCESS_MODE_DISABLED
	aura_range_outline.visible = false
	aura_area.visible = false
	aura_area.set_deferred("monitoring", false)
	aura_area.set_deferred("monitorable", false)
	aura_area_shape.set_deferred("disabled", true)
	aura_touched_player = null
	aura_damage_cooldown_left = 0.0


func _configure_aura_collision_mask() -> void:
	aura_area.collision_mask = PLAYER_COLLISION_MASK


func _ensure_player_aura_signals_connected() -> void:
	if not aura_area.body_entered.is_connected(_on_aura_area_body_entered):
		aura_area.body_entered.connect(_on_aura_area_body_entered)
	if not aura_area.body_exited.is_connected(_on_aura_area_body_exited):
		aura_area.body_exited.connect(_on_aura_area_body_exited)


func _configure_guardian_emission_budget() -> void:
	if (
		guardian_halo == null
		or guardian_light_emission == null
		or is_dead
		or not is_inside_tree()
	):
		return
	_set_guardian_emission_boost_enabled(false)
	add_to_group(GUARDIAN_EMISSION_CANDIDATE_GROUP)
	_try_claim_guardian_emission_budget()


func _try_claim_guardian_emission_budget() -> void:
	if (
		guardian_halo == null
		or guardian_light_emission == null
		or is_dead
		or not is_inside_tree()
	):
		return
	if not is_visible_in_tree():
		_release_guardian_emission_budget(false)
		return
	if is_in_group(GUARDIAN_EMISSION_ACTIVE_GROUP):
		_set_guardian_emission_boost_enabled(true)
		return
	if (
		get_tree().get_nodes_in_group(GUARDIAN_EMISSION_ACTIVE_GROUP).size()
		>= MAX_ACTIVE_GUARDIAN_EMISSION_BOOSTS
	):
		_set_guardian_emission_boost_enabled(false)
		return
	add_to_group(GUARDIAN_EMISSION_ACTIVE_GROUP)
	_set_guardian_emission_boost_enabled(true)


func _release_guardian_emission_budget(
	remove_candidate: bool = true
) -> void:
	if guardian_halo == null or guardian_light_emission == null:
		return
	var released_slot := is_in_group(GUARDIAN_EMISSION_ACTIVE_GROUP)
	if released_slot:
		remove_from_group(GUARDIAN_EMISSION_ACTIVE_GROUP)
	if remove_candidate and is_in_group(GUARDIAN_EMISSION_CANDIDATE_GROUP):
		remove_from_group(GUARDIAN_EMISSION_CANDIDATE_GROUP)
	_set_guardian_emission_boost_enabled(false)
	if released_slot and is_inside_tree():
		get_tree().call_group_flags(
			SceneTree.GROUP_CALL_DEFERRED,
			GUARDIAN_EMISSION_CANDIDATE_GROUP,
			&"_try_claim_guardian_emission_budget"
		)


func _on_guardian_visibility_changed() -> void:
	if is_dead or guardian_halo == null or guardian_light_emission == null:
		return
	if is_visible_in_tree():
		_try_claim_guardian_emission_budget()
	else:
		# 内嵌作战会把外层战场留在 SceneTree 中并隐藏。隐藏成员必须释放
		# 增强槽，但继续保留候选身份，恢复外层时才能自动重新认领。
		_release_guardian_emission_budget(false)


func _on_guardian_tree_entered() -> void:
	# `_ready()` only runs once. A live guardian removed and re-added to the tree
	# must restore its candidate membership after its child emission re-enters.
	call_deferred("_configure_guardian_emission_budget")


func _set_guardian_emission_boost_enabled(enabled: bool) -> void:
	if guardian_halo != null:
		guardian_halo.modulate = GUARDIAN_BASE_HALO_MODULATE
	if guardian_light_emission != null:
		guardian_light_emission.visible = enabled


# 光环区域检测到目标进入。
func _on_aura_area_body_entered(body: Node2D) -> void:
	if is_dead or not aura_active:
		return
	if config as YuanshiInsectGuardianConfig != null:
		return

	var player := body as Player
	if player == null:
		return

	aura_touched_player = player
	_try_deal_aura_damage()


# 目标离开光环区域。
func _on_aura_area_body_exited(body: Node2D) -> void:
	if config as YuanshiInsectGuardianConfig != null:
		return

	if body == aura_touched_player:
		aura_touched_player = null

# 每帧更新光环持续伤害冷却，在冷却结束后再次造成伤害。
func _update_aura_damage(delta: float) -> void:
	if not aura_active or _uses_centralized_guardian_aura():
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
		get_effective_attack_damage(config.attack_damage),
		_get_multiplayer_damage_source_id(int(Time.get_ticks_msec())),
		&"yuanshi_aura"
	)
	aura_damage_cooldown_left = aura_config.aura_damage_interval


func _die() -> void:
	if is_dead:
		return

	_release_guardian_emission_budget()
	_stop_aura()
	super._die()


func play_multiplayer_death_sequence() -> void:
	if is_dead:
		return
	# 代理死亡不发 Enemy.defeated；先关闭光环并同步撤销本地来源。
	_release_guardian_emission_budget()
	_stop_aura()
	super.play_multiplayer_death_sequence()
