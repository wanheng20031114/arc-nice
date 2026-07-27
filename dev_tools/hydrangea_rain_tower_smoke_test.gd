extends SceneTree

const HYDRANGEA_CONFIG := preload(
	"res://resources/config/plant_defense/hydrangea_rain_tower.tres"
)
const HYDRANGEA_BUILDING_ITEM := preload(
	"res://resources/config/buildings/building_hydrangea_rain_tower.tres"
)
const HYDRANGEA_SCENE := preload(
	"res://scene/plant_defense/hydrangea_rain_tower.tscn"
)
const PLACEMENT_PREVIEW_SCENE := preload(
	"res://scene/plant_defense/plant_placement_preview.tscn"
)
const INVENTORY_SLOT_SCENE := preload("res://scene/inventory_slot.tscn")
const PLAYER_SCENE := preload(
	"res://scene/player/hoe_cat/player_hoe_cat.tscn"
)
const ENEMY_CONFIG := preload(
	"res://resources/config/enemies/yuanshi_insect_basic.tres"
)

const EXPECTED_SOURCE_SIZE := Vector2(128.0, 128.0)
const EXPECTED_DISPLAY_SIZE := Vector2(32.0, 32.0)
const EXPECTED_SCALE := Vector2(0.25, 0.25)
const EXPECTED_HEAL := 50
const EXPECTED_MAGIC_DAMAGE := 5
const EXPECTED_ATTACK_MULTIPLIER := 0.8
const EXPECTED_RAIN_DURATION := 1.5
const EXPECTED_EFFECT_DURATION := 5.0
const EXPECTED_EFFECT_START_DELAY := 0.68
const EXPECTED_ACTION_DURATION := 5.68
const EXPECTED_TARGET_RADIUS_CELLS := 12.0
const EXPECTED_RAIN_RADIUS := 48.0
const EXPECTED_BLOOM_LIGHT_COLOR := Color(0.38, 0.44, 1.0, 1.0)
const EXPECTED_BLOOM_LIGHT_STRENGTH := 3.2

var failures: Array[String] = []
var fixture: RainTickRuntime
var scheduler: Node


class TargetCachePlantSystem:
	extends PlantSystem

	var available_targets: Array[PlantDefense] = []
	var logical_query_call_count := 0
	var last_center := Vector2.ZERO
	var last_radius_cells := 0.0

	func query_living_plants_in_logical_radius_into(
		center: Vector2,
		radius_cells: float,
		result: Array[PlantDefense]
	) -> void:
		logical_query_call_count += 1
		last_center = center
		last_radius_cells = radius_cells
		result.clear()
		result.append_array(available_targets)


class RainTickRuntime:
	extends Node2D

	var enemy_targets: Array[Enemy] = []
	var plant_targets: Array[PlantDefense] = []
	var player_targets: Array[Player] = []
	var combat_query_call_count := 0
	var damage_call_count := 0
	var player_heal_call_count := 0
	var combat_query_centers: Array[Vector2] = []
	var combat_query_radii: Array[float] = []
	var last_damage_source_id := 0
	var last_damage_amounts := PackedInt64Array()
	var last_damage_hit_counts := PackedInt32Array()
	var last_damage_type := -1
	var last_player_heal_amount := 0

	func query_combat_targets_unordered_into(
		center: Vector2,
		radius: float,
		result: Array[Enemy]
	) -> void:
		combat_query_call_count += 1
		combat_query_centers.append(center)
		combat_query_radii.append(radius)
		result.clear()
		result.append_array(enemy_targets)

	func query_living_plants_in_radius_into(
		_center: Vector2,
		_radius: float,
		result: Array[PlantDefense]
	) -> void:
		result.clear()
		result.append_array(plant_targets)

	func query_living_players_in_radius_into(
		_center: Vector2,
		_radius: float,
		result: Array[Player]
	) -> void:
		result.clear()
		result.append_array(player_targets)

	func apply_authoritative_plant_enemy_damage_batch(
		damage_source_id: int,
		enemy: Enemy,
		damage_amounts: PackedInt64Array,
		hit_counts: PackedInt32Array,
		impact_direction: Vector2,
		damage_type: EnemyConfig.DamageType
	) -> bool:
		damage_call_count += 1
		last_damage_source_id = damage_source_id
		last_damage_amounts = damage_amounts.duplicate()
		last_damage_hit_counts = hit_counts.duplicate()
		last_damage_type = damage_type
		return enemy.apply_damage_batch(
			damage_amounts,
			hit_counts,
			impact_direction,
			damage_type,
			false
		)

	func apply_authoritative_player_heal(
		target_player: Player,
		heal_amount: int
	) -> bool:
		player_heal_call_count += 1
		last_player_heal_amount = heal_amount
		return target_player._try_heal(heal_amount, false)


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	fixture = RainTickRuntime.new()
	fixture.name = "HydrangeaRainTowerSmokeFixture"
	root.add_child(fixture)
	current_scene = fixture
	scheduler = root.get_node("EnemyCollectibleStatusScheduler")
	scheduler.call("clear_all")

	_test_config_and_registration_contract()
	await _test_native_128_to_32_and_particle_contract()
	await _test_ground_dew_night_self_emission()
	await _test_two_stage_launch_visual()
	await _test_target_cache_and_injured_first_health_priority()
	await _test_delayed_impact_and_particle_tail_timeline()
	await _test_proxy_target_position_sync_and_deduplication()
	await _test_one_authoritative_rain_tick()
	await _test_overlapping_towers_stack_healing_not_reduction()

	scheduler.call("clear_all")
	fixture.queue_free()
	for _cleanup_frame in range(3):
		await process_frame
	fixture = null
	scheduler = null
	if failures.is_empty():
		print("HYDRANGEA_RAIN_TOWER_SMOKE_TEST_OK")
		quit(0)
		return
	for failure in failures:
		push_error(failure)
	quit(1)


func _test_config_and_registration_contract() -> void:
	var registered_config := PlantDefenseRegistry.get_config(
		PlantDefenseRegistry.HYDRANGEA_RAIN_TOWER_ID
	)
	_expect(
		registered_config == HYDRANGEA_CONFIG
		and PlantDefenseRegistry.is_valid_plant_id(&"hydrangea_rain_tower")
		and PlantDefenseRegistry.get_all_configs().has(HYDRANGEA_CONFIG),
		"紫阳花雨幕塔必须以稳定ID注册，并出现在完整植物配置列表中。"
	)
	_expect(
		HYDRANGEA_CONFIG is HydrangeaRainTowerConfig
		and HYDRANGEA_CONFIG.is_valid()
		and HYDRANGEA_CONFIG.max_health == 6000
		and HYDRANGEA_CONFIG.physical_defense == 10
		and HYDRANGEA_CONFIG.magic_defense == 40
		and HYDRANGEA_CONFIG.footprint_size == Vector2i(2, 2)
		and HYDRANGEA_CONFIG.supports_multiplayer,
		"紫阳花配置必须保持6000生命、10物防、40法防、2×2占格及多人支持。"
	)
	var rain_config := HYDRANGEA_CONFIG as HydrangeaRainTowerConfig
	_expect(
		rain_config != null
		and is_equal_approx(rain_config.rain_interval_seconds, 6.0)
		and is_equal_approx(
			rain_config.rain_duration_seconds,
			EXPECTED_RAIN_DURATION
		)
		and is_equal_approx(
			rain_config.effect_duration_seconds,
			EXPECTED_EFFECT_DURATION
		)
		and is_equal_approx(rain_config.rain_tick_interval_seconds, 1.0)
		and rain_config.healing_per_tick == EXPECTED_HEAL
		and rain_config.magic_damage_per_tick == EXPECTED_MAGIC_DAMAGE
		and is_equal_approx(
			rain_config.enemy_attack_damage_multiplier,
			EXPECTED_ATTACK_MULTIPLIER
		)
		and is_equal_approx(
			rain_config.target_search_radius_cells,
			EXPECTED_TARGET_RADIUS_CELLS
		)
		and is_equal_approx(rain_config.rain_radius, EXPECTED_RAIN_RADIUS),
		"雨幕必须为6秒周期、1.5秒落雨、5秒结算、12格选目标与3格作用半径。"
	)
	_expect(
		is_equal_approx(
			HydrangeaRainTowerConfig.RAIN_EMISSION_START_DELAY_SECONDS,
			0.24
		)
		and is_equal_approx(
			HydrangeaRainTowerConfig.RAIN_DROP_FALL_SECONDS,
			0.44
		)
		and is_equal_approx(
			HydrangeaRainTowerConfig.EFFECT_START_DELAY_SECONDS,
			EXPECTED_EFFECT_START_DELAY
		),
		"时间轴必须明确分为0.24秒起雨与0.44秒下落，治疗统一从0.68秒首次落地开始。"
	)


func _test_native_128_to_32_and_particle_contract() -> void:
	var tower := _make_tower(HYDRANGEA_CONFIG)
	var visual_root := tower.get_node("VisualRoot") as Node2D
	var main_sprite := tower.get_node("VisualRoot/MainSprite") as Sprite2D
	var launch_material := tower.dew_burst.process_material as ParticleProcessMaterial
	var launch_texture := tower.dew_burst.texture as GradientTexture2D
	var target_rain_material := (
		tower.target_rain_drops.process_material as ParticleProcessMaterial
	)
	var target_rain_texture := (
		tower.target_rain_drops.texture as GradientTexture2D
	)
	var ripple_material := (
		tower.target_rain_ripples.process_material as ParticleProcessMaterial
	)
	var ripple_texture := (
		tower.target_rain_ripples.texture as GradientTexture2D
	)
	var ripple_draw_material := (
		tower.target_rain_ripples.material as ShaderMaterial
	)
	var ground_material := (
		tower.ground_dew_rise.process_material as ParticleProcessMaterial
	)
	var ground_draw_material := (
		tower.ground_dew_rise.material as ShaderMaterial
	)
	var ground_texture := tower.ground_dew_rise.texture as GradientTexture2D
	var fall_distance := float(tower.call("_get_target_rain_fall_distance"))
	var fixed_fall_speed := fall_distance / tower.target_rain_drops.lifetime
	var target_drop_rate := (
		float(tower.target_rain_drops.amount) / tower.target_rain_drops.lifetime
	)
	var visible_ripple_ratio := float(
		ripple_draw_material.get_shader_parameter(&"visible_ratio")
	)
	var ground_mote_rate := (
		float(tower.ground_dew_rise.amount) / tower.ground_dew_rise.lifetime
	)
	var minimum_ripple_capacity := ceili(
		float(tower.target_rain_drops.amount)
		/ tower.target_rain_drops.lifetime
		* tower.target_rain_ripples.lifetime
		* target_rain_material.sub_emitter_amount_at_end
	)
	_expect(
		main_sprite.texture != null
		and main_sprite.texture.get_size() == EXPECTED_SOURCE_SIZE
		and visual_root.scale == EXPECTED_SCALE
		and main_sprite.texture.get_size() * visual_root.scale == EXPECTED_DISPLAY_SIZE
		and main_sprite.texture_filter == CanvasItem.TEXTURE_FILTER_NEAREST,
		"场景主体必须原生使用128×128贴图，并以0.25 nearest显示为32×32。"
	)
	_expect(
		launch_material != null
		and launch_texture != null
		and launch_texture.width == 1
		and launch_texture.height == 8
		and tower.dew_burst.amount == 72
		and is_equal_approx(tower.dew_burst.lifetime, 0.38)
		and is_equal_approx(tower.dew_burst.explosiveness, 0.35)
		and launch_material.particle_flag_align_y
		and launch_material.emission_shape
		== ParticleProcessMaterial.EMISSION_SHAPE_BOX
		and launch_material.emission_box_extents == Vector3(13.0, 1.5, 1.0)
		and launch_material.direction == Vector3(0.0, -1.0, 0.0)
		and is_zero_approx(launch_material.spread)
		and is_equal_approx(launch_material.initial_velocity_min, 170.0)
		and is_equal_approx(launch_material.initial_velocity_max, 230.0)
		and launch_material.color_initial_ramp != null
		and launch_material.color_ramp != null
		and target_rain_material != null
		and target_rain_material.resource_local_to_scene
		and target_rain_material.particle_flag_align_y
		and target_rain_material.emission_shape
		== ParticleProcessMaterial.EMISSION_SHAPE_RING
		and target_rain_material.emission_ring_axis
		== Vector3(0.0, 0.0, 1.0)
		and is_zero_approx(target_rain_material.emission_ring_height)
		and is_zero_approx(target_rain_material.emission_ring_inner_radius)
		and is_equal_approx(
			target_rain_material.emission_ring_radius,
			EXPECTED_RAIN_RADIUS
		)
		and target_rain_material.emission_shape_offset
		== Vector3(0.0, -fall_distance, 0.0)
		and target_rain_material.direction == Vector3(0.0, 1.0, 0.0)
		and is_zero_approx(target_rain_material.spread)
		and is_equal_approx(
			target_rain_material.initial_velocity_min,
			fixed_fall_speed
		)
		and is_equal_approx(
			target_rain_material.initial_velocity_max,
			fixed_fall_speed
		)
		and target_rain_material.gravity == Vector3.ZERO
		and is_zero_approx(target_rain_material.lifetime_randomness)
		and target_rain_material.sub_emitter_mode
		== ParticleProcessMaterial.SUB_EMITTER_AT_END
		and target_rain_material.sub_emitter_amount_at_end == 1
		and not target_rain_material.sub_emitter_keep_velocity
		and target_rain_texture != null
		and target_rain_texture.width == 1
		and target_rain_texture.height == 8
		and tower.target_rain_drops.amount == 144
		and target_drop_rate > 300.0
		and is_equal_approx(tower.target_rain_drops.lifetime, 0.44)
		and is_equal_approx(
			tower.effect_start_timer.wait_time,
			EXPECTED_EFFECT_START_DELAY
		)
		and is_equal_approx(
			tower.ground_effect_end_timer.wait_time,
			EXPECTED_ACTION_DURATION
		)
		and is_zero_approx(tower.target_rain_drops.randomness)
		and not tower.target_rain_drops.local_coords
		and tower.target_rain_drops.fixed_fps == 60
		and tower.target_rain_drops.use_fixed_seed
		and tower.target_rain_drops.sub_emitter
		== NodePath("../TargetRainRipples")
		and tower.target_rain_drops.get_node_or_null(
			tower.target_rain_drops.sub_emitter
		) == tower.target_rain_ripples
		and tower.target_rain_drops.visibility_rect.position.x
		<= -EXPECTED_RAIN_RADIUS
		and tower.target_rain_drops.visibility_rect.end.x
		>= EXPECTED_RAIN_RADIUS
		and tower.target_rain_drops.visibility_rect.position.y
		<= -fall_distance - EXPECTED_RAIN_RADIUS
		and tower.target_rain_drops.visibility_rect.end.y
		>= EXPECTED_RAIN_RADIUS
		and tower.target_rain_ripples.visibility_rect.position.x
		<= -EXPECTED_RAIN_RADIUS
		and tower.target_rain_ripples.visibility_rect.position.y
		<= -EXPECTED_RAIN_RADIUS
		and tower.target_rain_ripples.visibility_rect.end.x
		>= EXPECTED_RAIN_RADIUS
		and tower.target_rain_ripples.visibility_rect.end.y
		>= EXPECTED_RAIN_RADIUS
		and is_zero_approx(
			target_rain_material.emission_shape_offset.y
			+ fixed_fall_speed * tower.target_rain_drops.lifetime
		)
		and fall_distance > EXPECTED_RAIN_RADIUS * 2.0
		and not tower.target_rain_drops.one_shot
		and ripple_material != null
		and ripple_material.resource_local_to_scene
		and ripple_material.gravity == Vector3.ZERO
		and is_zero_approx(ripple_material.initial_velocity_min)
		and is_zero_approx(ripple_material.initial_velocity_max)
		and is_equal_approx(ripple_material.scale_min, 0.7)
		and is_equal_approx(ripple_material.scale_max, 1.0)
		and is_zero_approx(ripple_material.anim_offset_min)
		and is_equal_approx(ripple_material.anim_offset_max, 1.0)
		and ripple_material.color_initial_ramp != null
		and ripple_material.color_ramp != null
		and ripple_texture != null
		and ripple_texture.get_size() == Vector2(8.0, 8.0)
		and ripple_texture.width * ripple_material.scale_max <= 8.0
		and ripple_draw_material != null
		and ripple_draw_material.shader != null
		and ripple_draw_material.shader.code.contains("blend_mix")
		and not ripple_draw_material.shader.code.contains("blend_add")
		and ripple_draw_material.shader.code.contains("INSTANCE_CUSTOM.y")
		and ripple_draw_material.shader.code.contains("INSTANCE_CUSTOM.z")
		and ripple_draw_material.shader.code.contains("visible_ratio")
		and ripple_draw_material.shader.code.contains("length(centered)")
		and ripple_draw_material.shader.code.contains("ring_radius")
		and ripple_draw_material.shader.code.contains("fade_out")
		and is_equal_approx(visible_ripple_ratio, 0.18)
		and target_drop_rate * visible_ripple_ratio < 60.0
		and not tower.target_rain_ripples.emitting
		and not tower.target_rain_ripples.one_shot
		and not tower.target_rain_ripples.local_coords
		and tower.target_rain_ripples.use_fixed_seed
		and tower.target_rain_ripples.amount >= minimum_ripple_capacity
		and tower.target_rain_ripples.amount <= minimum_ripple_capacity + 24
		and ground_material != null
		and ground_material.color_initial_ramp != null
		and ground_material.color_ramp != null
		and tower.ground_dew_rise is NightSelfEmissionParticles2D
		and ground_draw_material != null
		and ground_draw_material.shader != null
		and ground_draw_material.shader.code.contains("blend_mix")
		and ground_draw_material.shader.code.contains("unshaded")
		and not ground_draw_material.shader.code.contains("blend_add")
		and ground_draw_material.shader.code.contains("night_factor")
		and ground_draw_material.shader.code.contains("environment_tint")
		and ground_draw_material.shader.code.contains("vec4 source = COLOR")
		and ground_draw_material.shader.code.contains("source.a")
		and is_equal_approx(
			float(ground_draw_material.get_shader_parameter(
				&"night_emission_strength"
			)),
			1.45
		)
		and is_zero_approx(float(
			tower.ground_dew_rise.get_instance_shader_parameter(
				&"night_factor"
			)
		))
		and ground_texture != null
		and ground_texture.get_size() == Vector2(1.0, 3.0)
		and ground_material.emission_shape
		== ParticleProcessMaterial.EMISSION_SHAPE_RING
		and ground_material.emission_ring_axis == Vector3(0.0, 0.0, 1.0)
		and is_zero_approx(ground_material.emission_ring_height)
		and is_zero_approx(ground_material.emission_ring_inner_radius)
		and is_equal_approx(
			ground_material.emission_ring_radius,
			EXPECTED_RAIN_RADIUS
		)
		and is_equal_approx(ground_material.initial_velocity_min, 10.0)
		and is_equal_approx(ground_material.initial_velocity_max, 20.0)
		and ground_material.gravity == Vector3(0.0, 4.0, 0.0)
		and is_equal_approx(ground_material.scale_min, 0.9)
		and is_equal_approx(ground_material.scale_max, 1.15)
		and tower.ground_dew_rise.amount == 96
		and is_equal_approx(tower.ground_dew_rise.lifetime, 1.0)
		and HydrangeaRainTower.GROUND_DEW_PARTICLE_TAIL_SECONDS
		>= tower.ground_dew_rise.lifetime
		and is_equal_approx(
			HYDRANGEA_CONFIG.rain_interval_seconds
			- HYDRANGEA_CONFIG.effect_duration_seconds,
			tower.ground_dew_rise.lifetime
		)
		and ground_mote_rate > 90.0
		and not tower.ground_dew_rise.one_shot
		and not tower.ground_dew_rise.local_coords,
		"目标雨必须低频触发像素级细波纹，同时以更清晰的彩色微粒持续表现地面作用范围。"
	)
	var rain_material := tower.rain_field.material as ShaderMaterial
	_expect(
		rain_material != null
		and rain_material.shader != null
		and rain_material.shader.code.contains("ground_aura")
		and rain_material.shader.code.contains("edge_ring")
		and not rain_material.shader.code.contains("rain_grid")
		and not rain_material.shader.code.contains("rain_columns"),
		"范围着色器只能保留柔和地面湿润光，不能再叠加与真实落点脱节的程序化雨幕。"
	)

	var idle_light_color := tower.core_night_light.color
	var idle_light_texture := tower.core_night_light.texture
	tower.core_night_light.set_night_factor(1.0)
	tower.bloom_core_night_light.set_night_factor(1.0)
	var idle_night_energy := tower.core_night_light.energy
	_expect(
		idle_light_texture != null
		and idle_light_texture.get_size() == Vector2(256.0, 256.0)
		and idle_light_texture.get_size().x
		* tower.core_night_light.texture_scale > 90.0
		and idle_night_energy > 0.0
		and is_zero_approx(tower.bloom_core_night_light.energy),
		"夜间待机必须保留原有大范围扩散光，开花核心灯则保持关闭。"
	)
	tower.call("_set_flower_state", true)
	_expect(
		tower.core_night_light.color == idle_light_color
		and tower.core_night_light.texture == idle_light_texture
		and is_equal_approx(
			tower.core_night_light.get_emission_strength(),
			1.0
		)
		and is_equal_approx(tower.core_night_light.energy, idle_night_energy)
		and tower.bloom_core_night_light.color == EXPECTED_BLOOM_LIGHT_COLOR
		and tower.bloom_core_night_light.texture != null
		and tower.bloom_core_night_light.texture.get_size()
		== Vector2(32.0, 32.0)
		and tower.bloom_core_night_light.texture.get_size().x
		* tower.bloom_core_night_light.texture_scale <= 12.0
		and is_equal_approx(
			tower.bloom_core_night_light.get_emission_strength(),
			EXPECTED_BLOOM_LIGHT_STRENGTH
		)
		and tower.bloom_core_night_light.energy > idle_night_energy * 3.0,
		"开花时必须保留扩散灯原状，并额外点亮高强度蓝紫色微型花蕊灯。"
	)
	tower.call("_set_flower_state", false)
	_expect(
		tower.core_night_light.color == idle_light_color
		and is_equal_approx(
			tower.core_night_light.get_emission_strength(),
			1.0
		)
		and is_equal_approx(tower.core_night_light.energy, idle_night_energy)
		and not tower.bloom_core_night_light.is_emission_allowed()
		and is_zero_approx(tower.bloom_core_night_light.energy),
		"花期结束后必须只关闭微型核心灯，原有扩散夜光继续保留。"
	)
	tower.core_night_light.set_night_factor(0.0)
	tower.bloom_core_night_light.set_night_factor(0.0)
	tower.call("_set_flower_state", true)
	_expect(
		is_zero_approx(tower.core_night_light.energy)
		and is_zero_approx(tower.bloom_core_night_light.energy),
		"白天即使处于开花状态也不得产生额外夜间光照。"
	)
	tower.call("_set_flower_state", false)

	var preview := PLACEMENT_PREVIEW_SCENE.instantiate() as PlantPlacementPreview
	fixture.add_child(preview)
	preview.configure(HYDRANGEA_CONFIG)
	_expect(
		preview.ghost_sprite.texture == HYDRANGEA_CONFIG.icon
		and preview.ghost_sprite.scale == EXPECTED_SCALE
		and preview.ghost_sprite.texture.get_size()
		* preview.ghost_sprite.scale == EXPECTED_DISPLAY_SIZE,
		"放置预览必须继续以0.25缩放128×128紫阳花素材。"
	)

	var inventory_slot := INVENTORY_SLOT_SCENE.instantiate() as InventorySlot
	fixture.add_child(inventory_slot)
	inventory_slot.set_item(HYDRANGEA_BUILDING_ITEM)
	_expect(
		HYDRANGEA_BUILDING_ITEM.icon_texture.get_size() == EXPECTED_SOURCE_SIZE
		and HYDRANGEA_BUILDING_ITEM.icon_scale == EXPECTED_SCALE
		and inventory_slot.item_icon.scale == EXPECTED_SCALE,
		"背包槽必须继续使用128×128源图与0.25缩放。"
	)

	inventory_slot.queue_free()
	preview.queue_free()
	tower.queue_free()
	await process_frame


func _test_ground_dew_night_self_emission() -> void:
	var controller := DayNightController.new()
	controller.name = "DayNightController"
	fixture.add_child(controller)
	var tower := _make_tower(HYDRANGEA_CONFIG)
	await process_frame
	await process_frame
	var ground_particles := (
		tower.ground_dew_rise as NightSelfEmissionParticles2D
	)
	tower.call("_prepare_ground_dew_rise_for_emission")
	controller.set_night_factor_immediate(0.0)
	_expect(
		ground_particles.emitting
		and is_zero_approx(float(
			ground_particles.get_instance_shader_parameter(&"night_factor")
		))
		and (
			ground_particles.get_instance_shader_parameter(
				&"environment_tint"
			) as Color
		).is_equal_approx(Color.WHITE),
		"白天的地面水珠必须保持普通粒子表现，不得残留自发光增益。"
	)
	controller.set_night_factor_immediate(0.5)
	_expect(
		is_equal_approx(float(
			ground_particles.get_instance_shader_parameter(&"night_factor")
		), 0.5)
		and (
			ground_particles.get_instance_shader_parameter(
				&"environment_tint"
			) as Color
		).is_equal_approx(controller.color),
		"昼夜过渡期间地面水珠的自发光必须随连续夜间因子平滑变化。"
	)
	controller.set_night_factor_immediate(1.0)
	_expect(
		is_equal_approx(float(
			ground_particles.get_instance_shader_parameter(&"night_factor")
		), 1.0)
		and ground_particles.emitting,
		"夜晚地面水珠必须保持发射，并启用完整的粒子自身发光。"
	)
	controller.set_night_factor_immediate(0.0)
	_expect(
		is_zero_approx(float(
			ground_particles.get_instance_shader_parameter(&"night_factor")
		))
		and ground_particles.emitting,
		"切回白天后必须立即清除夜间增益，同时保留正常地面粒子。"
	)
	tower.call("_hide_rain_visual_immediate")
	tower.queue_free()
	controller.queue_free()
	await process_frame
	await process_frame


func _test_two_stage_launch_visual() -> void:
	var tower := _make_tower(HYDRANGEA_CONFIG)
	var launch_material := (
		tower.dew_burst.process_material as ParticleProcessMaterial
	)
	var launch_speed_min := launch_material.initial_velocity_min
	var launch_speed_max := launch_material.initial_velocity_max
	var near_target := Vector2(64.0, 24.0)
	tower.call("_begin_rain_visual", near_target, 0.0)
	await process_frame
	var first_source_position := tower.dew_burst.global_position
	_expect(
		tower.rain_active
		and tower.dew_burst.emitting
		and is_zero_approx(tower.dew_burst.global_rotation)
		and not tower.rain_field.visible
		and not tower.target_rain_drops.emitting
		and not tower.target_rain_ripples.emitting
		and not tower.ground_dew_rise.emitting,
		"施法起点必须只在塔身向上喷发线性光雨，目标雨幕和地面粒子不得同帧出现。"
	)
	_expect(
		is_equal_approx(
			HydrangeaRainTower.TARGET_RAIN_START_DELAY_SECONDS,
			0.24
		),
		"上射线必须先独立表现0.24秒，目标雨不能过早同帧弹出。"
	)
	await create_timer(0.32, true, false, false).timeout
	await process_frame
	_expect(
		tower.rain_field.visible
		and tower.target_rain_drops.emitting
		and not tower.ground_dew_rise.emitting
		and is_zero_approx(tower.rain_field.global_rotation)
		and tower.rain_field.global_position == near_target
		and tower.target_rain_drops.global_position == near_target
		and tower.target_rain_ripples.global_position == near_target
		and tower.ground_dew_rise.global_position == near_target
		and tower.dew_burst.global_position == first_source_position,
		"约三分之一秒后目标竖直雨必须启动；地面氛围要等首批雨滴真正到达。"
	)
	await create_timer(
		tower.target_rain_drops.lifetime + 0.08,
		true,
		false,
		false
	).timeout
	await process_frame
	_expect(
		tower.target_rain_drops.emitting
		and tower.ground_dew_rise.emitting
		and tower.target_rain_drops.sub_emitter
		== NodePath("../TargetRainRipples"),
		"首批雨滴到达后才可启动地面回溅氛围，并保持逐滴波纹子发射链接。"
	)
	tower.call("_finish_rain_visual")
	tower.call("_hide_rain_visual_immediate")

	var far_target := Vector2(224.0, 144.0)
	tower.call("_begin_rain_visual", far_target, 0.0)
	await process_frame
	_expect(
		is_zero_approx(tower.dew_burst.global_rotation)
		and tower.dew_burst.global_position == first_source_position
		and is_equal_approx(
			launch_material.initial_velocity_min,
			launch_speed_min
		)
		and is_equal_approx(
			launch_material.initial_velocity_max,
			launch_speed_max
		)
		and not tower.rain_field.visible
		and not tower.target_rain_drops.emitting
		and not tower.target_rain_ripples.emitting
		and not tower.ground_dew_rise.emitting,
		"不同距离的治疗目标不得改变源点上喷方向或速度，也不得重新形成直飞目标的投射物。"
	)
	tower.call("_finish_rain_visual")
	tower.call("_hide_rain_visual_immediate")

	tower.call("_begin_rain_visual", far_target, 0.45)
	await process_frame
	_expect(
		not tower.dew_burst.emitting
		and tower.rain_field.visible
		and tower.target_rain_drops.emitting
		and not tower.ground_dew_rise.emitting
		and tower.rain_field.global_position == far_target
		and tower.target_rain_drops.global_position == far_target
		and tower.target_rain_ripples.global_position == far_target,
		"同步恢复到落雨阶段时必须跳过源点上喷，并按相位恢复首批落地延迟。"
	)
	tower.call("_finish_rain_visual")
	tower.call("_hide_rain_visual_immediate")
	tower.queue_free()
	await process_frame


func _test_target_cache_and_injured_first_health_priority() -> void:
	var tower := _make_tower(HYDRANGEA_CONFIG)
	var target_a := _make_tower(HYDRANGEA_CONFIG)
	var target_b := _make_tower(HYDRANGEA_CONFIG)
	var target_c := _make_tower(HYDRANGEA_CONFIG)
	target_a.current_health = 240
	target_b.max_health = 80
	target_b.current_health = 80
	target_c.current_health = 160
	var fake_system := TargetCachePlantSystem.new()
	fixture.add_child(fake_system)
	fake_system.available_targets.assign([target_a, target_b, target_c])
	tower.set_plant_system(fake_system)
	var first_selection := tower.call("_select_lowest_health_target") as PlantDefense
	var query_count_after_setup := fake_system.logical_query_call_count
	var repeated_selection := tower.call("_select_lowest_health_target") as PlantDefense
	_expect(
		query_count_after_setup == 1
		and fake_system.logical_query_call_count == 1
		and is_equal_approx(
			fake_system.last_radius_cells,
			EXPECTED_TARGET_RADIUS_CELLS
		)
		and first_selection == target_c
		and repeated_selection == target_c,
		"目标名单必须只初始化查询一次；12格内受伤建筑必须优先于当前生命值更低的满血建筑。"
	)

	target_a.current_health = 40
	var live_health_selection := (
		tower.call("_select_lowest_health_target") as PlantDefense
	)
	_expect(
		live_health_selection == target_a
		and fake_system.logical_query_call_count == 1,
		"生命值优先级必须在施法时读取实时值，不能为此重扫建筑名单。"
	)
	target_a.current_health = target_a.max_health
	target_c.current_health = target_c.max_health
	var all_full_selection := (
		tower.call("_select_lowest_health_target") as PlantDefense
	)
	_expect(
		all_full_selection == target_b
		and fake_system.logical_query_call_count == 1,
		"所有候选均满血时仍应按最低当前生命值选择，并保持缓存不重扫。"
	)
	fake_system.plant_placed.emit(target_c)
	fake_system.plant_removed.emit(target_c)
	_expect(
		fake_system.logical_query_call_count == 3,
		"可治疗建筑名单只能随建筑放置/移除事件刷新。"
	)

	tower.set_plant_system(null)
	fake_system.available_targets.clear()
	fake_system.queue_free()
	target_a.queue_free()
	target_b.queue_free()
	target_c.queue_free()
	tower.queue_free()
	await process_frame


func _test_delayed_impact_and_particle_tail_timeline() -> void:
	var short_config := HYDRANGEA_CONFIG.duplicate(true) as HydrangeaRainTowerConfig
	short_config.rain_interval_seconds = 2.0
	short_config.rain_duration_seconds = 0.85
	short_config.effect_duration_seconds = 1.0
	short_config.rain_tick_interval_seconds = 0.2
	var tower := _make_tower(short_config)
	var target_position := Vector2(96.0, 32.0)
	tower.current_health = tower.max_health - 300
	fixture.plant_targets.append(tower)
	var query_count_before := fixture.combat_query_call_count
	tower.call("_begin_authoritative_rain", target_position, 0.0)
	await create_timer(0.50, true, false, false).timeout
	await process_frame
	_expect(
		tower.rain_active
		and not tower.effect_active
		and not tower.effect_start_timer.is_stopped()
		and tower.rain_visual_phase
		== HydrangeaRainTower.RainVisualPhase.RAIN_DESCENT
		and tower.rain_field.visible
		and tower.target_rain_drops.emitting
		and not tower.ground_dew_rise.emitting
		and fixture.combat_query_call_count == query_count_before
		and tower.current_health == tower.max_health - 300,
		"雨滴尚未落地时只能播放下落视觉，不得提前治疗、伤害或减攻。"
	)
	await create_timer(0.24, true, false, false).timeout
	await process_frame
	_expect(
		tower.rain_active
		and tower.effect_active
		and tower.effect_start_timer.is_stopped()
		and tower.rain_visual_phase
		== HydrangeaRainTower.RainVisualPhase.GROUND_IMPACT
		and fixture.combat_query_call_count == query_count_before + 1
		and tower.current_health == tower.max_health - 250
		and tower.ground_dew_rise.emitting,
		"首批雨滴在0.68秒附近落地后，地面粒子与首个治疗结算必须同步启动。"
	)
	var active_runtime_state := tower.export_multiplayer_runtime_state()
	var exported_ground_elapsed := float(
		active_runtime_state.get("ground_effect_elapsed_seconds", -1.0)
	)
	_expect(
		bool(active_runtime_state.get("ground_effect_active", false))
		and exported_ground_elapsed >= EXPECTED_EFFECT_START_DELAY
		and exported_ground_elapsed < 0.9
		and active_runtime_state.get(
			"ground_effect_target_position",
			Vector2.ZERO
		) == target_position,
		"权威快照必须在落雨结束后仍能同步地面粒子的动作年龄与目标位置。"
	)
	await create_timer(0.16, true, false, false).timeout
	await process_frame
	_expect(
		not tower.rain_active
		and tower.effect_active
		and tower.rain_visual_phase
		== HydrangeaRainTower.RainVisualPhase.GROUND_SUSTAIN
		and tower.rain_field.visible
		and tower.rain_visual_intensity > 0.0
		and tower.rain_visual_intensity < 1.0
		and tower.target_rain_drops.emitting
		and tower.target_rain_drops.amount_ratio > 0.0
		and tower.target_rain_drops.amount_ratio < 1.0
		and tower.target_rain_drops.self_modulate.a > 0.0
		and tower.target_rain_drops.self_modulate.a < 1.0
		and tower.ground_dew_rise.emitting
		and is_equal_approx(tower.ground_dew_rise.amount_ratio, 1.0)
		and is_equal_approx(tower.ground_dew_rise.self_modulate.a, 1.0)
		and tower.main_sprite.texture == tower.idle_texture
		and tower.upper_canopy.texture == tower.rain_upper_texture
		and tower.upper_canopy.self_modulate.a > 0.0
		and tower.upper_canopy.self_modulate.a < 1.0
		and is_equal_approx(
			tower.core_night_light.get_emission_strength(),
			1.0
		)
		and tower.bloom_core_night_light.get_emission_strength() > 0.0
		and tower.bloom_core_night_light.get_emission_strength()
		< EXPECTED_BLOOM_LIGHT_STRENGTH,
		"落雨窗口结束后花冠、雨线与地面范围应消散，但地面粒子必须满强度覆盖剩余治疗窗口。"
	)
	await create_timer(0.72, true, false, false).timeout
	await process_frame
	_expect(
		tower.effect_active
		and tower.ground_dew_rise.emitting
		and is_equal_approx(tower.ground_dew_rise.amount_ratio, 1.0)
		and is_equal_approx(tower.ground_dew_rise.self_modulate.a, 1.0)
		and not tower.ground_effect_end_timer.is_stopped(),
		"从首批落地起计算的效果窗口结束前，治疗、减攻和地面粒子必须同时保持活动。"
	)
	await create_timer(0.12, true, false, false).timeout
	await process_frame
	var completed_tick_count := (
		fixture.combat_query_call_count - query_count_before
	)
	var all_queries_target_centered := true
	for index in range(
		fixture.combat_query_centers.size() - completed_tick_count,
		fixture.combat_query_centers.size()
	):
		all_queries_target_centered = (
			all_queries_target_centered
			and fixture.combat_query_centers[index] == target_position
			and is_equal_approx(
				fixture.combat_query_radii[index],
				EXPECTED_RAIN_RADIUS
			)
		)
	_expect(
		completed_tick_count == 5
		and not tower.effect_active
		and tower.effect_start_timer.is_stopped()
		and tower.rain_tick_timer.is_stopped()
		and tower.effect_end_timer.is_stopped()
		and tower.ground_effect_end_timer.is_stopped()
		and not tower.ground_dew_rise.emitting
		and is_zero_approx(tower.ground_dew_rise.amount_ratio)
		and tower.ground_dew_rise.self_modulate.a > 0.0
		and tower.ground_dew_rise.self_modulate.a < 1.0
		and tower.rain_visual_phase
		== HydrangeaRainTower.RainVisualPhase.DISSIPATING
		and all_queries_target_centered,
		"完整效果必须在落地后结算5次，地面粒子只能在效果结束后停止新增并进入尾声。"
	)
	_expect(
		tower.current_health == tower.max_health - 50,
		"5秒效果窗口必须实际执行5个每次50点的建筑治疗tick。"
	)
	await create_timer(0.12, true, false, false).timeout
	await process_frame
	_expect(
		not tower.rain_field.visible
		and is_zero_approx(tower.rain_visual_intensity)
		and not tower.ground_dew_rise.emitting
		and tower.ground_dew_rise.self_modulate.a > 0.0
		and tower.ground_dew_rise.self_modulate.a < 1.0
		and tower.rain_visual_phase
		== HydrangeaRainTower.RainVisualPhase.DISSIPATING,
		"地面范围光消失后，地面水珠必须仍保留至少一个完整粒子尾声期。"
	)
	await create_timer(1.15, true, false, false).timeout
	await process_frame
	_expect(
		not tower.rain_field.visible
		and is_zero_approx(tower.rain_visual_intensity)
		and not tower.target_rain_drops.emitting
		and is_equal_approx(tower.target_rain_drops.amount_ratio, 1.0)
		and tower.target_rain_drops.self_modulate == Color.WHITE
		and not tower.target_rain_ripples.emitting
		and is_equal_approx(tower.target_rain_ripples.amount_ratio, 1.0)
		and tower.target_rain_ripples.self_modulate == Color.WHITE
		and not tower.ground_dew_rise.emitting
		and is_equal_approx(tower.ground_dew_rise.amount_ratio, 1.0)
		and tower.ground_dew_rise.self_modulate == Color.WHITE
		and tower.rain_visual_phase == HydrangeaRainTower.RainVisualPhase.IDLE,
		"粒子尾声结束后所有雨幕节点必须停止并恢复到可重用待机状态。"
	)
	fixture.plant_targets.clear()
	tower.queue_free()
	await process_frame


func _test_proxy_target_position_sync_and_deduplication() -> void:
	var target_position := Vector2(72.0, 40.0)
	var newer_target_position := Vector2(104.0, 56.0)
	var constructing_proxy := HYDRANGEA_SCENE.instantiate() as HydrangeaRainTower
	fixture.add_child(constructing_proxy)
	constructing_proxy.setup(
		HYDRANGEA_CONFIG,
		null,
		_footprint_cells(),
		true,
		-1,
		0,
		-1,
		true
	)
	constructing_proxy.apply_multiplayer_runtime_state(
		{
			"schema": HydrangeaRainTower.RUNTIME_STATE_SCHEMA,
			"cycle_elapsed_seconds": 2.35,
			"rain_active": true,
			"rain_action_id": 2,
			"rain_elapsed_seconds": 0.35,
			"rain_target_position": target_position,
		},
		0.0
	)
	constructing_proxy.play_multiplayer_rain_action(
		3,
		newer_target_position,
		0.35
	)
	_expect(
		constructing_proxy.pending_proxy_has_action_visual
		and constructing_proxy.rain_action_id == 3
		and constructing_proxy.pending_proxy_action_target_position
		== newer_target_position
		and constructing_proxy.cycle_timer.is_stopped(),
		"施工中的代理必须缓存较新动作的目标位置与已计入包龄的雨幕相位。"
	)
	constructing_proxy.call("_stop_construction_tween")
	constructing_proxy.call("_finish_construction", false)
	_expect(
		constructing_proxy.rain_active
		and constructing_proxy.rain_field.global_position == newer_target_position
		and constructing_proxy.target_rain_drops.emitting
		and constructing_proxy.target_rain_drops.global_position
		== newer_target_position
		and constructing_proxy.target_rain_ripples.global_position
		== newer_target_position
		and constructing_proxy.ground_dew_rise.global_position
		== newer_target_position
		and not constructing_proxy.ground_dew_rise.emitting
		and not constructing_proxy.dew_burst.emitting,
		"代理转为可运行后必须在主机指定建筑位置恢复雨幕。"
	)
	constructing_proxy.queue_free()
	await process_frame

	var live_proxy := HYDRANGEA_SCENE.instantiate() as HydrangeaRainTower
	fixture.add_child(live_proxy)
	live_proxy.setup(HYDRANGEA_CONFIG, null, _footprint_cells(), true)
	live_proxy.apply_multiplayer_runtime_state(
		{
			"schema": HydrangeaRainTower.RUNTIME_STATE_SCHEMA,
			"cycle_elapsed_seconds": 6.05,
			"rain_active": false,
			"rain_action_id": 7,
		},
		0.0
	)
	_expect(
		not live_proxy.rain_active and live_proxy.rain_action_id == 7,
		"跨过周期边界的快照不能在客户端臆造一个未知目标的雨幕。"
	)
	live_proxy.play_multiplayer_rain_action(8, target_position, 0.05)
	var first_synced_position := live_proxy.rain_field.global_position
	live_proxy.play_multiplayer_rain_action(8, Vector2(999.0, 999.0), 0.1)
	live_proxy.apply_multiplayer_runtime_state(
		{
			"schema": HydrangeaRainTower.RUNTIME_STATE_SCHEMA,
			"cycle_elapsed_seconds": 1.0,
			"rain_active": true,
			"rain_action_id": 7,
			"rain_elapsed_seconds": 0.1,
			"rain_target_position": Vector2(999.0, 999.0),
		},
		0.0
	)
	_expect(
		live_proxy.rain_active
		and live_proxy.rain_action_id == 8
		and first_synced_position == target_position
		and live_proxy.rain_field.global_position == target_position,
		"可靠雨幕动作必须同步目标位置，并拒绝重复动作及旧快照覆盖。"
	)
	live_proxy.play_multiplayer_rain_action(9, target_position, 1.7)
	_expect(
		not live_proxy.rain_active
		and live_proxy.rain_action_id == 9
		and live_proxy.ground_dew_rise.emitting
		and live_proxy.ground_dew_rise.global_position == target_position
		and not live_proxy.ground_effect_end_timer.is_stopped()
		and live_proxy.rain_visual_phase
		== HydrangeaRainTower.RainVisualPhase.GROUND_SUSTAIN,
		"包龄超过1.5秒的动作不得重播落雨，但必须恢复至5.68秒的地面粒子。"
	)
	live_proxy.apply_multiplayer_runtime_state(
		{
			"schema": HydrangeaRainTower.RUNTIME_STATE_SCHEMA,
			"cycle_elapsed_seconds": 2.2,
			"rain_active": false,
			"ground_effect_active": true,
			"rain_action_id": 10,
			"ground_effect_elapsed_seconds": 2.2,
			"ground_effect_target_position": newer_target_position,
		},
		0.0
	)
	_expect(
		not live_proxy.rain_active
		and live_proxy.rain_action_id == 10
		and live_proxy.ground_dew_rise.emitting
		and live_proxy.ground_dew_rise.global_position
		== newer_target_position
		and live_proxy.ground_effect_end_timer.time_left > 3.3
		and live_proxy.ground_effect_end_timer.time_left < 3.5,
		"中途加入客户端必须从快照恢复完整效果期内剩余的地面粒子时长。"
	)
	live_proxy.play_multiplayer_rain_action(11, target_position, 5.8)
	_expect(
		not live_proxy.rain_active
		and live_proxy.rain_action_id == 11
		and not live_proxy.ground_dew_rise.emitting
		and live_proxy.ground_effect_end_timer.is_stopped(),
		"包龄超过5.68秒的动作不得重新发射已经结束的地面粒子。"
	)
	live_proxy.queue_free()
	await process_frame


func _test_one_authoritative_rain_tick() -> void:
	var tower := _make_tower(HYDRANGEA_CONFIG)
	var target_position := Vector2(80.0, 48.0)
	var player := PLAYER_SCENE.instantiate() as Player
	fixture.add_child(player)
	player.set_controls_locked(true)
	player.set_physics_process(false)
	player.current_health = maxi(player.max_health - 60, 1)
	player.health_bar.set_health(player.current_health, player.max_health)

	var enemy := ENEMY_CONFIG.enemy_scene.instantiate() as Enemy
	fixture.add_child(enemy)
	enemy.setup(ENEMY_CONFIG, player, null)
	enemy.set_physics_process(false)
	var enemy_health_before := enemy.current_health
	tower.current_health = tower.max_health - 100
	tower.health_bar.set_health(tower.current_health, tower.max_health)
	var tower_health_before := tower.current_health
	var player_health_before := player.current_health

	fixture.enemy_targets.append(enemy)
	fixture.plant_targets.append(tower)
	fixture.player_targets.append(player)
	tower.effect_active = true
	tower.rain_target_global_position = target_position
	tower.effect_started_at_seconds = float(tower.call("_now_seconds"))
	var effect_source_id := int(tower.call("_get_effect_source_id"))
	var damage_count_before := fixture.damage_call_count
	var player_heal_count_before := fixture.player_heal_call_count
	tower.call("_apply_authoritative_rain_tick", 0)
	_expect(
		fixture.damage_call_count == damage_count_before + 1
		and fixture.last_damage_source_id == effect_source_id
		and fixture.last_damage_amounts == PackedInt64Array([EXPECTED_MAGIC_DAMAGE])
		and fixture.last_damage_hit_counts == PackedInt32Array([1])
		and fixture.last_damage_type == EnemyConfig.DamageType.MAGIC
		and enemy.current_health == enemy_health_before - EXPECTED_MAGIC_DAMAGE,
		"可见雨幕tick必须经权威网关对敌人造成5点法术伤害。"
	)
	_expect(
		tower.current_health == tower_health_before + EXPECTED_HEAL
		and fixture.player_heal_call_count == player_heal_count_before + 1
		and fixture.last_player_heal_amount == EXPECTED_HEAL
		and player.current_health == player_health_before + EXPECTED_HEAL,
		"结算tick必须为目标区域内植物与玩家各恢复50点生命。"
	)
	_expect(
		is_equal_approx(
			enemy.get_outgoing_attack_damage_multiplier(),
			EXPECTED_ATTACK_MULTIPLIER
		)
		and enemy.get_effective_attack_damage(10) == 8,
		"结算tick必须把敌人有效攻击力降为80%。"
	)
	scheduler.call("advance_for_test", 4.9)
	_expect(
		is_equal_approx(
			enemy.get_outgoing_attack_damage_multiplier(),
			EXPECTED_ATTACK_MULTIPLIER
		),
		"减攻状态必须覆盖完整5秒效果窗口。"
	)
	scheduler.call("advance_for_test", 0.2)
	_expect(
		is_equal_approx(enemy.get_outgoing_attack_damage_multiplier(), 1.0),
		"5秒效果窗口结束后减攻必须恢复。"
	)

	var damage_count_before_hidden_tick := fixture.damage_call_count
	var player_heal_count_before_hidden_tick := fixture.player_heal_call_count
	var tower_health_before_hidden_tick := tower.current_health
	var player_health_before_hidden_tick := player.current_health
	tower.effect_started_at_seconds = float(tower.call("_now_seconds")) - 3.0
	tower.call("_apply_authoritative_rain_tick", 3)
	_expect(
		fixture.damage_call_count == damage_count_before_hidden_tick
		and fixture.player_heal_call_count
		== player_heal_count_before_hidden_tick + 1
		and tower.current_health == tower_health_before_hidden_tick + EXPECTED_HEAL
		and player.current_health == mini(
			player_health_before_hidden_tick + EXPECTED_HEAL,
			player.max_health
		)
		and is_equal_approx(
			enemy.get_outgoing_attack_damage_multiplier(),
			EXPECTED_ATTACK_MULTIPLIER
		),
		"第3秒后隐藏阶段仍治疗和减攻，但不得追加可见雨幕的法术伤害。"
	)

	fixture.enemy_targets.clear()
	fixture.plant_targets.clear()
	fixture.player_targets.clear()
	tower.effect_active = false
	tower.queue_free()
	enemy.queue_free()
	player.queue_free()
	await process_frame


func _test_overlapping_towers_stack_healing_not_reduction() -> void:
	var tower_a := _make_tower(HYDRANGEA_CONFIG)
	var tower_b := _make_tower(HYDRANGEA_CONFIG)
	var healing_target := _make_tower(HYDRANGEA_CONFIG)
	var target_position := Vector2(96.0, 64.0)
	var player := PLAYER_SCENE.instantiate() as Player
	fixture.add_child(player)
	player.set_controls_locked(true)
	player.set_physics_process(false)

	var enemy := ENEMY_CONFIG.enemy_scene.instantiate() as Enemy
	fixture.add_child(enemy)
	enemy.setup(ENEMY_CONFIG, player, null)
	enemy.set_physics_process(false)
	healing_target.current_health = healing_target.max_health - EXPECTED_HEAL * 3
	healing_target.health_bar.set_health(
		healing_target.current_health,
		healing_target.max_health
	)
	var healing_before := healing_target.current_health
	var enemy_health_before := enemy.current_health
	var source_a := int(tower_a.call("_get_effect_source_id"))
	var source_b := int(tower_b.call("_get_effect_source_id"))

	fixture.enemy_targets.append(enemy)
	fixture.plant_targets.append(healing_target)
	for tower in [tower_a, tower_b]:
		tower.effect_active = true
		tower.rain_target_global_position = target_position
		tower.effect_started_at_seconds = float(tower.call("_now_seconds"))
		tower.call("_apply_authoritative_rain_tick", 0)

	_expect(
		source_a != source_b
		and enemy.collectible_status_effects.size() == 2
		and enemy.outgoing_attack_damage_multiplier_modifiers.size() == 2
		and is_equal_approx(
			enemy.get_outgoing_attack_damage_multiplier(),
			EXPECTED_ATTACK_MULTIPLIER
		)
		and enemy.get_effective_attack_damage(10) == 8,
		"多个紫阳花必须保留各自减攻时长，但最终20%减攻只能取一次，禁止乘算叠加为36%。"
	)
	_expect(
		healing_target.current_health == healing_before + EXPECTED_HEAL * 2
		and enemy.current_health == enemy_health_before - EXPECTED_MAGIC_DAMAGE * 2,
		"多个紫阳花的每次50点治疗与可见雨幕伤害必须按塔独立结算并允许相加。"
	)

	fixture.enemy_targets.clear()
	fixture.plant_targets.clear()
	enemy.clear_collectible_statuses()
	for tower in [tower_a, tower_b]:
		tower.effect_active = false
		tower.queue_free()
	healing_target.queue_free()
	enemy.queue_free()
	player.queue_free()
	await process_frame


func _make_tower(
	new_config: HydrangeaRainTowerConfig
) -> HydrangeaRainTower:
	var tower := HYDRANGEA_SCENE.instantiate() as HydrangeaRainTower
	fixture.add_child(tower)
	tower.setup(new_config, null, _footprint_cells())
	tower.cycle_timer.stop()
	tower.rain_tick_timer.stop()
	tower.rain_end_timer.stop()
	tower.effect_end_timer.stop()
	return tower


func _footprint_cells() -> Array[Vector2i]:
	return [
		Vector2i.ZERO,
		Vector2i.RIGHT,
		Vector2i.DOWN,
		Vector2i.ONE,
	]


func _expect(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)
