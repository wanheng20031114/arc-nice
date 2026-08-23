extends Node2D
class_name TowerDefensePrewarmerCoordinator

const PLAYER_BULLET_POOL_SCENE := preload("res://scene/combat/projectiles/bullet.tscn")
const TANGO_LASER_BULLET_POOL_SCENE := preload(
	"res://scene/player/tango/tango_laser_bullet.tscn"
)
const CAPOO_AK47_BULLET_POOL_SCENE := preload(
	"res://scene/enemy/capoo/capoo_ak47_bullet.tscn"
)
const COMBAT_ROBOT_SUICIDE_DRONE_POOL_SCENE := preload(
	"res://scene/enemy/mechanical_life/combat_robot_suicide_drone.tscn"
)
const COMBAT_ROBOT_SUICIDE_DRONE_ELITE_POOL_SCENE := preload(
	"res://scene/enemy/mechanical_life/combat_robot_suicide_drone_elite.tscn"
)
const CAPOO_SMG_BULLET_POOL_SCENE := preload(
	"res://scene/enemy/capoo/capoo_smg_bullet.tscn"
)
const FIRE_SORCERER_FIREBALL_VOLLEY_POOL_SCENE := preload(
	"res://scene/enemy/sorcerer/fire_sorcerer_fireball_volley.tscn"
)
const FIRE_SORCERER_ELITE_FIREBALL_VOLLEY_POOL_SCENE := preload(
	"res://scene/enemy/sorcerer/fire_sorcerer_elite_fireball_volley.tscn"
)
const FROST_SORCERER_ICE_SPIKE_POOL_SCENE := preload(
	"res://scene/enemy/sorcerer/frost_sorcerer_ice_spike.tscn"
)
const YUANSHI_FIRE_PROJECTILE_POOL_SCENE := preload(
	"res://scene/enemy/yuanshi_insect/yuanshi_insect_fire_projectile.tscn"
)
const AGAVE_CANNONBALL_POOL_SCENE := preload(
	"res://scene/plant_defense/agave_cannonball.tscn"
)
const BAMBOO_MORTAR_SHELL_POOL_SCENE := preload(
	"res://scene/plant_defense/bamboo_mortar_shell.tscn"
)
const COLLECTIBLE_ARROW_POOL_SCENE := preload(
	"res://scene/combat/collectibles/collectible_arrow_projectile.tscn"
)
const COLLECTIBLE_SAKURA_ROCKET_POOL_SCENE := preload(
	"res://scene/combat/collectibles/collectible_sakura_rocket.tscn"
)
const LINGLAN_SKILL1_BULLET_POOL_SCENE := preload(
	"res://scene/boss/linglan/linglan_skill1_sakura_bullet.tscn"
)
const LINGLAN_SAKURA_HIT_EFFECT_POOL_SCENE := preload(
	"res://scene/boss/linglan/linglan_sakura_hit_effect.tscn"
)

const PLANT_LIFECYCLE_VFX_PREWARM_COUNT := 8
const PLANT_LIFECYCLE_VFX_RETAINED_CAPACITY := 32
# Wave 9 can have roughly 120 AK rounds alive concurrently. Instantiate that
# steady-state set while the loading mask is active instead of growing the
# elastic gameplay pool on synchronized attacks. Mage fireballs are data rows.
const LEGACY_CAPOO_AK47_BULLET_PREWARM_COUNT := 32
const EXPANDED_CAPOO_AK47_BULLET_PREWARM_COUNT := 128

@onready var plant_lifecycle_shader_prewarm: Sprite2D = (
	$PlantLifecycleShaderPrewarm
)
@onready var bamboo_mortar_lifecycle_shader_prewarm: Sprite2D = (
	$BambooMortarLifecycleShaderPrewarm
)
@onready var bamboo_mortar_glow_shader_prewarm: Polygon2D = (
	$BambooMortarGlowShaderPrewarm
)

var navigation_prewarm_requested := false
var navigation_prewarmed := false
var plant_lifecycle_shader_prewarmed := false
var projectile_pool_registration_ms := 0.0

var runtime: TowerDefenseGame = null
var tower_grid_pathfinder: GridPathfinder = null
var map_camera: Camera2D = null
var session_object_pool: SessionObjectPool = null
var boss_coordinator: TowerDefenseBossCoordinator = null
var fate_coordinator: FateCoordinator = null
var placement_particles_scene: PackedScene = null
var removal_smoke_scene: PackedScene = null
var guardian_point_light_texture: Texture2D = null
var waves: Array[WaveConfig] = []


func setup(
	runtime_instance: TowerDefenseGame,
	grid_pathfinder_instance: GridPathfinder,
	camera_instance: Camera2D,
	object_pool: SessionObjectPool,
	boss_runtime_coordinator: TowerDefenseBossCoordinator,
	fate_runtime_coordinator: FateCoordinator,
	wave_configs: Array[WaveConfig],
	plant_placement_particles_scene: PackedScene,
	plant_removal_smoke_scene: PackedScene,
	guardian_texture: Texture2D
) -> bool:
	if runtime_instance == null:
		push_error("TowerDefensePrewarmerCoordinator: 缺少 TowerDefenseGame。")
		return false
	if grid_pathfinder_instance == null:
		push_error("TowerDefensePrewarmerCoordinator: GridPathfinder 强类型绑定失败。")
		return false
	if camera_instance == null or object_pool == null:
		push_error("TowerDefensePrewarmerCoordinator: 缺少相机或对象池。")
		return false
	if boss_runtime_coordinator == null or fate_runtime_coordinator == null:
		push_error("TowerDefensePrewarmerCoordinator: 缺少 Boss/Fate 预热依赖。")
		return false
	if (
		plant_placement_particles_scene == null
		or plant_removal_smoke_scene == null
		or guardian_texture == null
	):
		push_error("TowerDefensePrewarmerCoordinator: 缺少预热资源。")
		return false

	runtime = runtime_instance
	tower_grid_pathfinder = grid_pathfinder_instance
	map_camera = camera_instance
	session_object_pool = object_pool
	boss_coordinator = boss_runtime_coordinator
	fate_coordinator = fate_runtime_coordinator
	waves = wave_configs
	placement_particles_scene = plant_placement_particles_scene
	removal_smoke_scene = plant_removal_smoke_scene
	guardian_point_light_texture = guardian_texture
	return true


func is_bound() -> bool:
	return (
		runtime != null
		and tower_grid_pathfinder != null
		and map_camera != null
		and session_object_pool != null
		and boss_coordinator != null
		and fate_coordinator != null
	)


func can_continue_runtime_prewarm(preparation_generation: int) -> bool:
	return (
		is_bound()
		and runtime._can_continue_runtime_prewarm(preparation_generation)
	)


func prewarm_enemy_visual_resources() -> void:
	if guardian_point_light_texture != null:
		guardian_point_light_texture.get_size()


func register_runtime_object_pools(expanded_projectile_prewarm: bool) -> void:
	if session_object_pool == null:
		push_error("TowerDefensePrewarmerCoordinator: 对象池尚未绑定。")
		return
	prewarm_enemy_visual_resources()
	CombatRuntimeBase.register_common_visual_effect_pools(session_object_pool)
	session_object_pool.register_scene(
		placement_particles_scene,
		PLANT_LIFECYCLE_VFX_PREWARM_COUNT,
		PLANT_LIFECYCLE_VFX_RETAINED_CAPACITY
	)
	session_object_pool.register_scene(
		removal_smoke_scene,
		PLANT_LIFECYCLE_VFX_PREWARM_COUNT,
		PLANT_LIFECYCLE_VFX_RETAINED_CAPACITY
	)
	var registration_started_usec := Time.get_ticks_usec()
	session_object_pool.register_scene(PLAYER_BULLET_POOL_SCENE, 64, 768)
	session_object_pool.register_scene(TANGO_LASER_BULLET_POOL_SCENE, 64, 768)
	session_object_pool.register_scene(
		CAPOO_AK47_BULLET_POOL_SCENE,
		(
			EXPANDED_CAPOO_AK47_BULLET_PREWARM_COUNT
			if expanded_projectile_prewarm
			else LEGACY_CAPOO_AK47_BULLET_PREWARM_COUNT
		),
		384
	)
	CombatRuntimeBase.register_combat_robot_gunner_bullet_pool(session_object_pool)
	CombatRuntimeBase.register_combat_robot_gunner_elite_bullet_pool(session_object_pool)
	session_object_pool.register_scene(COMBAT_ROBOT_SUICIDE_DRONE_POOL_SCENE, 0, 384)
	session_object_pool.register_scene(COMBAT_ROBOT_SUICIDE_DRONE_ELITE_POOL_SCENE, 0, 384)
	session_object_pool.register_scene(CAPOO_SMG_BULLET_POOL_SCENE, 48, 512)
	# A 7 s flight plus expiry visuals slightly overlaps a third 3.6 s attack
	# cycle. Capacity includes those visual-only leases and release quarantine.
	session_object_pool.register_scene(
		FIRE_SORCERER_FIREBALL_VOLLEY_POOL_SCENE,
		48,
		704
	)
	session_object_pool.register_scene(
		FIRE_SORCERER_ELITE_FIREBALL_VOLLEY_POOL_SCENE,
		48,
		704
	)
	# One 7 s ice spike spans two 3.6 s cast cycles. Capacity intentionally
	# covers the 300-enemy gameplay probe while prewarm stays loading-friendly.
	session_object_pool.register_scene(FROST_SORCERER_ICE_SPIKE_POOL_SCENE, 48, 704)
	projectile_pool_registration_ms = float(
		Time.get_ticks_usec() - registration_started_usec
	) / 1000.0
	session_object_pool.register_scene(YUANSHI_FIRE_PROJECTILE_POOL_SCENE, 48, 384)
	session_object_pool.register_scene(AGAVE_CANNONBALL_POOL_SCENE, 48, 384)
	# The formal synchronized ceiling is 100 mortars. Prewarm the complete first
	# volley during loading so gameplay never pays a 64 -> 100 expansion.
	session_object_pool.register_scene(BAMBOO_MORTAR_SHELL_POOL_SCENE, 100, 384)
	session_object_pool.register_scene(COLLECTIBLE_ARROW_POOL_SCENE, 48, 384)
	session_object_pool.register_scene(COLLECTIBLE_SAKURA_ROCKET_POOL_SCENE, 16, 128)
	# 18 rings/s * 20 directions * 2 s lifetime = 720 live bullets. The retained
	# headroom covers the pool's one-physics-frame release quarantine.
	session_object_pool.register_scene(LINGLAN_SKILL1_BULLET_POOL_SCENE, 64, 768)
	# A 0.16 s effect at the same peak fire rate needs about 58 concurrent leases.
	session_object_pool.register_scene(LINGLAN_SAKURA_HIT_EFFECT_POOL_SCENE, 16, 96)


func schedule_boss_runtime_scene_loads(preparation_generation: int) -> void:
	if not is_bound() or DisplayServer.get_name() == "headless":
		return
	await get_tree().process_frame
	if not runtime._can_continue_runtime_prewarm(preparation_generation):
		return
	await get_tree().process_frame
	if runtime._can_continue_runtime_prewarm(preparation_generation):
		boss_coordinator.request_runtime_scene_loads(preparation_generation)


func schedule_enemy_navigation_prewarm(preparation_generation: int) -> void:
	if not is_bound() or runtime.runtime_mode == CombatRuntimeBase.RuntimeMode.CLIENT_VIEW:
		return
	if navigation_prewarmed or navigation_prewarm_requested:
		return
	if not runtime._can_continue_runtime_prewarm(preparation_generation):
		return
	navigation_prewarm_requested = true
	call_deferred(
		"_run_scheduled_enemy_navigation_prewarm",
		preparation_generation
	)


func prepare_shared_runtime_data_and_complete(preparation_generation: int) -> void:
	if not is_bound():
		return
	await _prewarm_tower_shared_runtime_data(preparation_generation)
	if not runtime._can_continue_runtime_prewarm(preparation_generation):
		return
	await _prewarm_plant_lifecycle_shader(preparation_generation)
	if (
		runtime._can_continue_runtime_prewarm(preparation_generation)
	):
		runtime.mark_runtime_preparation_complete(preparation_generation)


func ensure_navigation_prewarmed_sync() -> void:
	if (
		not is_bound()
		or runtime.runtime_mode == CombatRuntimeBase.RuntimeMode.CLIENT_VIEW
		or navigation_prewarmed
	):
		return
	_prewarm_enemy_navigation_grids()
	# Preserve the legacy wave-start fallback: even an unavailable/unbuilt grid
	# consumes the one synchronous attempt before WAVE_ACTIVE begins.
	navigation_prewarmed = true


func _run_scheduled_enemy_navigation_prewarm(preparation_generation: int) -> void:
	await get_tree().process_frame
	if not runtime._can_continue_runtime_prewarm(preparation_generation):
		return
	await get_tree().process_frame
	if not runtime._can_continue_runtime_prewarm(preparation_generation):
		return
	navigation_prewarm_requested = false
	if navigation_prewarmed:
		await _finish_shared_runtime_prewarm(preparation_generation)
		return
	await _prewarm_enemy_navigation_grids_staged(preparation_generation)
	if not runtime._can_continue_runtime_prewarm(preparation_generation):
		return
	navigation_prewarmed = true
	await _finish_shared_runtime_prewarm(preparation_generation)


func _finish_shared_runtime_prewarm(preparation_generation: int) -> void:
	await _prewarm_tower_shared_runtime_data(preparation_generation)
	if not runtime._can_continue_runtime_prewarm(preparation_generation):
		return
	await _prewarm_plant_lifecycle_shader(preparation_generation)
	if (
		runtime._can_continue_runtime_prewarm(preparation_generation)
	):
		runtime.mark_runtime_preparation_complete(preparation_generation)


func _prewarm_tower_shared_runtime_data(preparation_generation: int) -> void:
	await runtime.prewarm_shared_runtime_data(preparation_generation)
	if not runtime._can_continue_runtime_prewarm(preparation_generation):
		return
	if not await boss_coordinator.prewarm_runtime_resources(preparation_generation):
		runtime.mark_runtime_preparation_failed(
			preparation_generation,
			boss_coordinator.runtime_preparation_failure_reason
		)
		return
	if not runtime._can_continue_runtime_prewarm(preparation_generation):
		return
	if not await fate_coordinator.prewarm_elite_enemy_configs():
		runtime.mark_runtime_preparation_failed(
			preparation_generation,
			fate_coordinator.runtime_preparation_failure_reason
		)


func _prewarm_enemy_navigation_grids() -> void:
	if tower_grid_pathfinder == null or not tower_grid_pathfinder.is_built:
		return
	var profiles := _collect_unique_enemy_profiles()
	var navigation_targets := _collect_navigation_targets()
	for profile in profiles:
		var half_extents: Vector2 = profile["half_extents"]
		var traversal_types: int = int(profile["traversal_types"])
		tower_grid_pathfinder.prewarm_agent_grid(half_extents, traversal_types)
		for navigation_target in navigation_targets:
			if navigation_target == null or not is_instance_valid(navigation_target):
				continue
			tower_grid_pathfinder.prewarm_flow_navigation_target(
				navigation_target.global_position,
				half_extents,
				traversal_types
			)


func _prewarm_enemy_navigation_grids_staged(
	preparation_generation: int
) -> void:
	runtime.update_runtime_preparation_progress(
		preparation_generation,
		"分析塔防敌人体型…",
		0,
		1
	)
	await get_tree().process_frame
	if (
		not runtime._can_continue_runtime_prewarm(preparation_generation)
		or not tower_grid_pathfinder.is_built
	):
		return

	var profiles := await _collect_unique_enemy_profiles_staged(
		preparation_generation
	)
	if not runtime._can_continue_runtime_prewarm(preparation_generation):
		return
	var navigation_targets := _collect_navigation_targets()
	var total_steps := maxi(profiles.size() * (1 + navigation_targets.size()), 1)
	var completed_steps := 0
	runtime.update_runtime_preparation_progress(
		preparation_generation,
		"预热塔防寻路网格…",
		completed_steps,
		total_steps
	)
	for profile in profiles:
		var half_extents: Vector2 = profile["half_extents"]
		var traversal_types: int = int(profile["traversal_types"])
		await tower_grid_pathfinder.prewarm_agent_grid_staged(
			half_extents,
			traversal_types
		)
		if not runtime._can_continue_runtime_prewarm(preparation_generation):
			return
		completed_steps += 1
		runtime.update_runtime_preparation_progress(
			preparation_generation,
			"预热塔防寻路网格…",
			completed_steps,
			total_steps
		)
		await get_tree().process_frame
		if not runtime._can_continue_runtime_prewarm(preparation_generation):
			return
		for navigation_target in navigation_targets:
			if navigation_target == null or not is_instance_valid(navigation_target):
				completed_steps += 1
				continue
			await tower_grid_pathfinder.prewarm_flow_navigation_target_staged(
				navigation_target.global_position,
				half_extents,
				traversal_types
			)
			if not runtime._can_continue_runtime_prewarm(preparation_generation):
				return
			completed_steps += 1
			runtime.update_runtime_preparation_progress(
				preparation_generation,
				"预热 Home 防线…",
				completed_steps,
				total_steps
			)
			await get_tree().process_frame
			if not runtime._can_continue_runtime_prewarm(preparation_generation):
				return


func _collect_unique_enemy_profiles() -> Array[Dictionary]:
	var profiles: Array[Dictionary] = []
	var seen_scene_keys: Dictionary = {}
	var seen_extent_keys: Dictionary = {}
	for wave_config in waves:
		if wave_config == null:
			continue
		for entry in wave_config.enemy_entries:
			if entry == null or entry.enemy_config == null:
				continue
			var enemy_config := entry.enemy_config
			if enemy_config.enemy_scene == null:
				continue
			var scene_key := enemy_config.enemy_scene.resource_path
			if scene_key.is_empty():
				scene_key = enemy_config.resource_path
			if seen_scene_keys.has(scene_key):
				continue
			seen_scene_keys[scene_key] = true
			var body_half_extents := _get_enemy_scene_body_half_extents(enemy_config)
			if body_half_extents == Vector2.ZERO:
				continue
			var traversal_types := enemy_config.terrain_traversal_types
			var extent_key := "%d:%d:%d" % [
				ceili(body_half_extents.x),
				ceili(body_half_extents.y),
				traversal_types,
			]
			if seen_extent_keys.has(extent_key):
				continue
			seen_extent_keys[extent_key] = true
			profiles.append({
				"half_extents": body_half_extents,
				"traversal_types": traversal_types,
			})
	return profiles


func _collect_unique_enemy_profiles_staged(
	preparation_generation: int
) -> Array[Dictionary]:
	var profiles: Array[Dictionary] = []
	var seen_scene_keys: Dictionary = {}
	var seen_extent_keys: Dictionary = {}
	for wave_config in waves:
		if wave_config == null:
			continue
		for entry in wave_config.enemy_entries:
			if entry == null or entry.enemy_config == null:
				continue
			var enemy_config := entry.enemy_config
			if enemy_config.enemy_scene == null:
				continue
			var scene_key := enemy_config.enemy_scene.resource_path
			if scene_key.is_empty():
				scene_key = enemy_config.resource_path
			if seen_scene_keys.has(scene_key):
				continue
			seen_scene_keys[scene_key] = true
			var body_half_extents := _get_enemy_scene_body_half_extents(enemy_config)
			await get_tree().process_frame
			if not runtime._can_continue_runtime_prewarm(preparation_generation):
				return profiles
			if body_half_extents == Vector2.ZERO:
				continue
			var traversal_types := enemy_config.terrain_traversal_types
			var extent_key := "%d:%d:%d" % [
				ceili(body_half_extents.x),
				ceili(body_half_extents.y),
				traversal_types,
			]
			if seen_extent_keys.has(extent_key):
				continue
			seen_extent_keys[extent_key] = true
			profiles.append({
				"half_extents": body_half_extents,
				"traversal_types": traversal_types,
			})
	return profiles


func _collect_navigation_targets() -> Array[Node2D]:
	var navigation_targets: Array[Node2D] = []
	if runtime.player != null:
		navigation_targets.append(runtime.player)
	navigation_targets.append_array(runtime.get_home_objective_targets())
	return navigation_targets


func _get_enemy_scene_body_half_extents(enemy_config: EnemyConfig) -> Vector2:
	if enemy_config == null or enemy_config.enemy_scene == null:
		return Vector2.ZERO
	var instance := enemy_config.enemy_scene.instantiate()
	var enemy_instance := instance as Enemy
	if enemy_instance == null:
		if instance != null:
			instance.free()
		return Vector2.ZERO
	var body_half_extents := enemy_instance.get_configured_body_collision_half_extents()
	enemy_instance.free()
	return body_half_extents


func _prewarm_plant_lifecycle_shader(preparation_generation: int) -> void:
	if (
		not runtime._can_continue_runtime_prewarm(preparation_generation)
		or plant_lifecycle_shader_prewarmed
		or not runtime.runtime_activation_deferred
		or plant_lifecycle_shader_prewarm == null
		or bamboo_mortar_lifecycle_shader_prewarm == null
		or bamboo_mortar_glow_shader_prewarm == null
	):
		return
	runtime.update_runtime_preparation_progress(
		preparation_generation,
		"预热植物生命周期特效…",
		0,
		1
	)
	var prewarm_position := map_camera.get_screen_center_position()
	plant_lifecycle_shader_prewarm.global_position = prewarm_position
	bamboo_mortar_lifecycle_shader_prewarm.global_position = prewarm_position
	bamboo_mortar_glow_shader_prewarm.global_position = prewarm_position
	plant_lifecycle_shader_prewarm.set_instance_shader_parameter(
		&"construction_progress",
		0.5
	)
	plant_lifecycle_shader_prewarm.set_instance_shader_parameter(
		&"construction_front_strength",
		1.0
	)
	plant_lifecycle_shader_prewarm.set_instance_shader_parameter(&"removal_enabled", true)
	plant_lifecycle_shader_prewarm.set_instance_shader_parameter(&"removal_progress", 0.5)
	plant_lifecycle_shader_prewarm.show()
	bamboo_mortar_lifecycle_shader_prewarm.show()
	bamboo_mortar_glow_shader_prewarm.show()

	var placement_particles := session_object_pool.try_acquire(
		placement_particles_scene
	) as GPUParticles2D
	if placement_particles != null:
		placement_particles.global_position = prewarm_position
		placement_particles.reset_physics_interpolation()
		placement_particles.amount_ratio = 1.0
		placement_particles.restart()
		placement_particles.emitting = true
	var removal_smoke := session_object_pool.try_acquire(
		removal_smoke_scene
	) as GPUParticles2D
	if removal_smoke != null:
		removal_smoke.global_position = prewarm_position
		removal_smoke.reset_physics_interpolation()
		removal_smoke.restart()
		removal_smoke.emitting = true
	if DisplayServer.get_name() == "headless":
		await get_tree().process_frame
	else:
		await RenderingServer.frame_post_draw
	if not runtime._can_continue_runtime_prewarm(preparation_generation):
		return
	plant_lifecycle_shader_prewarm.hide()
	bamboo_mortar_lifecycle_shader_prewarm.hide()
	bamboo_mortar_glow_shader_prewarm.hide()
	if placement_particles != null:
		placement_particles.emitting = false
		placement_particles.amount_ratio = 0.0
		SessionObjectPool.release_to_owner(placement_particles)
	if removal_smoke != null:
		removal_smoke.emitting = false
		SessionObjectPool.release_to_owner(removal_smoke)
	if not is_inside_tree():
		return
	plant_lifecycle_shader_prewarmed = true
	runtime.update_runtime_preparation_progress(
		preparation_generation,
		"预热植物生命周期特效…",
		1,
		1
	)
