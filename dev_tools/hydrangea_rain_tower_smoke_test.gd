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
const EXPECTED_EFFECT_DURATION := 5.0
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
	var last_damage_amounts := PackedInt32Array()
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
		damage_amounts: PackedInt32Array,
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
	await _test_target_cache_and_lowest_current_health_priority()
	await _test_three_second_visual_and_five_second_effect_timeline()
	await _test_proxy_target_position_sync_and_deduplication()
	await _test_one_authoritative_rain_tick()

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
		and is_equal_approx(rain_config.rain_duration_seconds, 3.0)
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
		"雨幕必须为6秒周期、3秒可见、5秒结算、12格选目标与3格作用半径。"
	)


func _test_native_128_to_32_and_particle_contract() -> void:
	var tower := _make_tower(HYDRANGEA_CONFIG)
	var visual_root := tower.get_node("VisualRoot") as Node2D
	var main_sprite := tower.get_node("VisualRoot/MainSprite") as Sprite2D
	var launch_material := tower.dew_burst.process_material as ParticleProcessMaterial
	var ground_material := (
		tower.ground_dew_rise.process_material as ParticleProcessMaterial
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
		and launch_material.color_initial_ramp != null
		and launch_material.color_ramp != null
		and ground_material != null
		and ground_material.color_initial_ramp != null
		and ground_material.color_ramp != null
		and is_equal_approx(
			ground_material.emission_sphere_radius,
			EXPECTED_RAIN_RADIUS
		)
		and tower.ground_dew_rise.amount == 84
		and not tower.ground_dew_rise.one_shot,
		"发射雨滴与84个地面上升粒子必须从预设紫阳花色带随机取初始色，地面发射盘半径为3格。"
	)

	var idle_light_color := tower.core_night_light.color
	tower.core_night_light.set_night_factor(1.0)
	var idle_night_energy := tower.core_night_light.energy
	tower.call("_set_flower_state", true)
	_expect(
		tower.core_night_light.color == EXPECTED_BLOOM_LIGHT_COLOR
		and is_equal_approx(
			tower.core_night_light.get_emission_strength(),
			EXPECTED_BLOOM_LIGHT_STRENGTH
		)
		and tower.core_night_light.energy > idle_night_energy * 3.0,
		"开花状态必须在夜间发出显著增强的蓝紫色中心光。"
	)
	tower.call("_set_flower_state", false)
	_expect(
		tower.core_night_light.color == idle_light_color
		and is_equal_approx(
			tower.core_night_light.get_emission_strength(),
			1.0
		)
		and is_equal_approx(tower.core_night_light.energy, idle_night_energy),
		"花期结束后必须恢复原有夜间核心光。"
	)
	tower.core_night_light.set_night_factor(0.0)
	tower.call("_set_flower_state", true)
	_expect(
		is_zero_approx(tower.core_night_light.energy),
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


func _test_target_cache_and_lowest_current_health_priority() -> void:
	var tower := _make_tower(HYDRANGEA_CONFIG)
	var target_a := _make_tower(HYDRANGEA_CONFIG)
	var target_b := _make_tower(HYDRANGEA_CONFIG)
	var target_c := _make_tower(HYDRANGEA_CONFIG)
	target_a.current_health = 240
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
		and first_selection == target_b
		and repeated_selection == target_b,
		"目标名单必须只初始化查询一次，并按12格内最低当前生命值选择建筑。"
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


func _test_three_second_visual_and_five_second_effect_timeline() -> void:
	var short_config := HYDRANGEA_CONFIG.duplicate(true) as HydrangeaRainTowerConfig
	short_config.rain_interval_seconds = 1.2
	short_config.rain_duration_seconds = 0.6
	short_config.effect_duration_seconds = 1.0
	short_config.rain_tick_interval_seconds = 0.2
	var tower := _make_tower(short_config)
	var target_position := Vector2(96.0, 32.0)
	tower.current_health = tower.max_health - 300
	fixture.plant_targets.append(tower)
	var query_count_before := fixture.combat_query_call_count
	tower.call("_begin_authoritative_rain", target_position, 0.0)
	await create_timer(0.48, true, false, false).timeout
	await process_frame
	_expect(
		tower.rain_active and tower.effect_active and tower.rain_field.visible,
		"3秒视觉窗口结束前，目标雨幕必须仍然可见。"
	)
	await create_timer(0.18, true, false, false).timeout
	await process_frame
	_expect(
		not tower.rain_active
		and tower.effect_active
		and not tower.rain_field.visible
		and tower.ground_dew_rise.emitting
		and tower.ground_dew_rise.amount_ratio > 0.0
		and tower.ground_dew_rise.amount_ratio < 1.0
		and tower.ground_dew_rise.self_modulate.a > 0.0
		and tower.ground_dew_rise.self_modulate.a < 1.0
		and tower.main_sprite.texture == tower.idle_texture
		and tower.upper_canopy.texture == tower.rain_upper_texture
		and tower.upper_canopy.self_modulate.a > 0.0
		and tower.upper_canopy.self_modulate.a < 1.0
		and tower.core_night_light.get_emission_strength() > 1.0
		and tower.core_night_light.get_emission_strength()
		< EXPECTED_BLOOM_LIGHT_STRENGTH,
		"第3秒雨幕必须结束；花冠、夜光与地面粒子应从该时刻开始平滑闭合、减量和渐隐。"
	)
	await create_timer(0.12, true, false, false).timeout
	await process_frame
	_expect(
		tower.effect_active,
		"第5秒效果窗口结束前，治疗与减攻结算必须仍保持活动。"
	)
	await create_timer(0.25, true, false, false).timeout
	await process_frame
	_expect(
		tower.main_sprite.texture == tower.idle_texture
		and tower.upper_canopy.texture == tower.idle_upper_texture
		and tower.upper_canopy.self_modulate == Color.WHITE
		and tower.upper_canopy.scale == Vector2.ONE
		and is_equal_approx(
			tower.core_night_light.get_emission_strength(),
			1.0
		)
		and tower.ground_dew_rise.emitting
		and tower.ground_dew_rise.self_modulate.a < 1.0,
		"短时反向收缩结束后花冠与夜光必须恢复待机态，持续粒子则继续完成尾部消散。"
	)
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
		and tower.rain_tick_timer.is_stopped()
		and tower.effect_end_timer.is_stopped()
		and all_queries_target_centered,
		"完整技能必须围绕选中建筑的3格范围恰好结算5次，且在第5秒结束。"
	)
	_expect(
		tower.current_health == tower.max_health - 50,
		"5秒效果窗口必须实际执行5个每次50点的建筑治疗tick。"
	)
	await create_timer(0.3, true, false, false).timeout
	await process_frame
	_expect(
		not tower.ground_dew_rise.emitting
		and is_equal_approx(tower.ground_dew_rise.amount_ratio, 1.0)
		and tower.ground_dew_rise.self_modulate == Color.WHITE,
		"粒子消散完成后必须停止并恢复可复用的发射比例与透明度。"
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
		constructing_proxy.pending_proxy_has_rain
		and constructing_proxy.rain_action_id == 3
		and constructing_proxy.pending_proxy_rain_target_position
		== newer_target_position
		and constructing_proxy.cycle_timer.is_stopped(),
		"施工中的代理必须缓存较新动作的目标位置与已计入包龄的雨幕相位。"
	)
	constructing_proxy.call("_stop_construction_tween")
	constructing_proxy.call("_finish_construction", false)
	_expect(
		constructing_proxy.rain_active
		and constructing_proxy.rain_field.global_position == newer_target_position
		and constructing_proxy.ground_dew_rise.global_position
		== newer_target_position
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
	live_proxy.play_multiplayer_rain_action(9, target_position, 3.2)
	_expect(
		not live_proxy.rain_active and live_proxy.rain_action_id == 9,
		"包龄超过3秒的可靠动作不得重新显示已经结束的雨幕。"
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
		and fixture.last_damage_amounts == PackedInt32Array([EXPECTED_MAGIC_DAMAGE])
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
