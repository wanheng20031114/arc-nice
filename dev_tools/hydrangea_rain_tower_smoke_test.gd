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
const EXPECTED_STATUS_DURATION := 3.0

var failures: Array[String] = []
var fixture: RainTickRuntime
var scheduler: Node


class RainTickRuntime:
	extends Node2D

	var enemy_targets: Array[Enemy] = []
	var plant_targets: Array[PlantDefense] = []
	var player_targets: Array[Player] = []
	var combat_query_call_count := 0
	var damage_call_count := 0
	var player_heal_call_count := 0
	var last_damage_source_id := 0
	var last_damage_amounts := PackedInt32Array()
	var last_damage_hit_counts := PackedInt32Array()
	var last_damage_type := -1
	var last_player_heal_amount := 0

	func query_combat_targets_unordered_into(
		_center: Vector2,
		_radius: float,
		result: Array[Enemy]
	) -> void:
		combat_query_call_count += 1
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
	await _test_native_128_to_32_display_contract()
	await _test_complete_rain_has_exactly_three_ticks()
	await _test_proxy_runtime_state_preserves_packet_aged_phase()
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
		"紫阳花配置必须有效，并保持6000生命、10物防、40法防、2×2占格及多人支持。"
	)
	var rain_config := HYDRANGEA_CONFIG as HydrangeaRainTowerConfig
	_expect(
		rain_config != null
		and is_equal_approx(rain_config.rain_interval_seconds, 10.0)
		and is_equal_approx(rain_config.rain_duration_seconds, 3.0)
		and is_equal_approx(rain_config.rain_tick_interval_seconds, 1.0)
		and rain_config.healing_per_tick == EXPECTED_HEAL
		and rain_config.magic_damage_per_tick == EXPECTED_MAGIC_DAMAGE
		and is_equal_approx(
			rain_config.enemy_attack_damage_multiplier,
			EXPECTED_ATTACK_MULTIPLIER
		)
		and is_equal_approx(
			rain_config.attack_reduction_duration_seconds,
			EXPECTED_STATUS_DURATION
		)
		and is_equal_approx(rain_config.rain_radius, 160.0),
		"雨幕必须为10秒间隔、3秒持续、1秒tick、50治疗、5法伤、0.8减攻与160半径。"
	)


func _test_native_128_to_32_display_contract() -> void:
	var tower := HYDRANGEA_SCENE.instantiate() as HydrangeaRainTower
	fixture.add_child(tower)
	var footprint_cells: Array[Vector2i] = [
		Vector2i.ZERO,
		Vector2i.RIGHT,
		Vector2i.DOWN,
		Vector2i.ONE,
	]
	tower.setup(HYDRANGEA_CONFIG, null, footprint_cells)
	tower.cycle_timer.stop()
	var visual_root := tower.get_node("VisualRoot") as Node2D
	var main_sprite := tower.get_node("VisualRoot/MainSprite") as Sprite2D
	_expect(
		main_sprite.texture != null
		and main_sprite.texture.get_size() == EXPECTED_SOURCE_SIZE
		and visual_root.scale == EXPECTED_SCALE
		and main_sprite.texture.get_size() * visual_root.scale == EXPECTED_DISPLAY_SIZE
		and main_sprite.texture_filter == CanvasItem.TEXTURE_FILTER_NEAREST,
		"场景主体必须原生使用128×128贴图，并仅以0.25 nearest缩放显示为32×32。"
	)

	var preview := PLACEMENT_PREVIEW_SCENE.instantiate() as PlantPlacementPreview
	fixture.add_child(preview)
	preview.configure(HYDRANGEA_CONFIG)
	_expect(
		preview.ghost_sprite.texture == HYDRANGEA_CONFIG.icon
		and preview.ghost_sprite.scale == EXPECTED_SCALE
		and preview.ghost_sprite.texture.get_size()
		* preview.ghost_sprite.scale == EXPECTED_DISPLAY_SIZE,
		"放置预览必须按源贴图尺寸把128×128紫阳花缩放为32×32。"
	)

	var inventory_slot := INVENTORY_SLOT_SCENE.instantiate() as InventorySlot
	fixture.add_child(inventory_slot)
	inventory_slot.set_item(HYDRANGEA_BUILDING_ITEM)
	_expect(
		HYDRANGEA_BUILDING_ITEM.icon_texture.get_size() == EXPECTED_SOURCE_SIZE
		and HYDRANGEA_BUILDING_ITEM.icon_scale == EXPECTED_SCALE
		and inventory_slot.item_icon.texture == HYDRANGEA_BUILDING_ITEM.icon_texture
		and inventory_slot.item_icon.scale == EXPECTED_SCALE
		and inventory_slot.item_icon.texture.get_size()
		* inventory_slot.item_icon.scale == EXPECTED_DISPLAY_SIZE,
		"背包槽必须直接使用128×128源图与物品0.25缩放，最终显示为32×32。"
	)

	inventory_slot.queue_free()
	preview.queue_free()
	tower.queue_free()
	await process_frame


func _test_one_authoritative_rain_tick() -> void:
	var tower := HYDRANGEA_SCENE.instantiate() as HydrangeaRainTower
	fixture.add_child(tower)
	var footprint_cells: Array[Vector2i] = [
		Vector2i.ZERO,
		Vector2i.RIGHT,
		Vector2i.DOWN,
		Vector2i.ONE,
	]
	tower.setup(HYDRANGEA_CONFIG, null, footprint_cells)
	tower.cycle_timer.stop()
	tower.rain_tick_timer.stop()
	tower.rain_end_timer.stop()

	var player := PLAYER_SCENE.instantiate() as Player
	fixture.add_child(player)
	player.set_controls_locked(true)
	player.set_physics_process(false)
	# Hoe Cat's authored 80 HP leaves enough missing health to observe the full
	# 50-point rain tick without changing the player's configured maximum.
	player.current_health = maxi(player.max_health - 60, 1)
	player.health_bar.set_health(player.current_health, player.max_health)

	var enemy := ENEMY_CONFIG.enemy_scene.instantiate() as Enemy
	fixture.add_child(enemy)
	enemy.setup(ENEMY_CONFIG, player, null)
	enemy.set_physics_process(false)
	var enemy_health_before := enemy.current_health
	var tower_health_before := tower.max_health - 100
	tower.current_health = tower_health_before
	tower.health_bar.set_health(tower.current_health, tower.max_health)
	var player_health_before := player.current_health

	fixture.enemy_targets.append(enemy)
	fixture.plant_targets.append(tower)
	fixture.player_targets.append(player)

	var effect_source_id := int(tower.call("_get_effect_source_id"))
	_apply_attack_reduction(enemy, effect_source_id, EXPECTED_STATUS_DURATION)
	scheduler.call("advance_for_test", 2.5)
	_expect(
		is_equal_approx(
			enemy.get_outgoing_attack_damage_multiplier(),
			EXPECTED_ATTACK_MULTIPLIER
		),
		"刷新探针开始前，敌人必须仍处于即将到期的20%减攻状态。"
	)

	tower.rain_active = true
	tower.call("_apply_authoritative_rain_tick")
	_expect(
		fixture.damage_call_count == 1
		and fixture.last_damage_source_id == effect_source_id
		and fixture.last_damage_amounts == PackedInt32Array([EXPECTED_MAGIC_DAMAGE])
		and fixture.last_damage_hit_counts == PackedInt32Array([1])
		and fixture.last_damage_type == EnemyConfig.DamageType.MAGIC
		and enemy.current_health == enemy_health_before - EXPECTED_MAGIC_DAMAGE,
		"一次雨幕tick必须经权威批处理网关对敌人造成恰好5点法术伤害。"
	)
	_expect(
		tower.current_health == tower_health_before + EXPECTED_HEAL,
		"一次雨幕tick必须为范围内友方植物恢复50点生命。"
	)
	_expect(
		fixture.player_heal_call_count == 1
		and fixture.last_player_heal_amount == EXPECTED_HEAL
		and player.current_health == player_health_before + EXPECTED_HEAL
		and player.last_healing_received == EXPECTED_HEAL,
		"一次雨幕tick必须经权威治疗网关为范围内玩家恢复50点生命。"
	)
	_expect(
		is_equal_approx(
			enemy.get_outgoing_attack_damage_multiplier(),
			EXPECTED_ATTACK_MULTIPLIER
		)
		and enemy.get_effective_attack_damage(10) == 8,
		"雨幕tick必须把敌人有效攻击力降为80%。"
	)

	scheduler.call("advance_for_test", 0.6)
	_expect(
		is_equal_approx(
			enemy.get_outgoing_attack_damage_multiplier(),
			EXPECTED_ATTACK_MULTIPLIER
		),
		"雨幕tick必须刷新同源状态，原期限过去后减攻仍需生效。"
	)
	scheduler.call("advance_for_test", 2.39)
	_expect(
		is_equal_approx(
			enemy.get_outgoing_attack_damage_multiplier(),
			EXPECTED_ATTACK_MULTIPLIER
		),
		"刷新后的20%减攻必须持续完整的新3秒期限。"
	)
	scheduler.call("advance_for_test", 0.01)
	_expect(
		is_equal_approx(enemy.get_outgoing_attack_damage_multiplier(), 1.0),
		"刷新后的减攻必须在新的3秒期限结束时恢复为1.0。"
	)

	fixture.enemy_targets.clear()
	fixture.plant_targets.clear()
	fixture.player_targets.clear()
	tower.rain_active = false
	tower.queue_free()
	enemy.queue_free()
	player.queue_free()
	await process_frame


func _test_complete_rain_has_exactly_three_ticks() -> void:
	var short_config := HYDRANGEA_CONFIG.duplicate(true) as HydrangeaRainTowerConfig
	short_config.rain_interval_seconds = 30.0
	short_config.rain_duration_seconds = 0.3
	short_config.rain_tick_interval_seconds = 0.1
	var tower := HYDRANGEA_SCENE.instantiate() as HydrangeaRainTower
	fixture.add_child(tower)
	var footprint_cells: Array[Vector2i] = [
		Vector2i.ZERO,
		Vector2i.RIGHT,
		Vector2i.DOWN,
		Vector2i.ONE,
	]
	tower.setup(short_config, null, footprint_cells)
	tower.cycle_timer.stop()
	var query_count_before := fixture.combat_query_call_count
	tower.call("_begin_rain", 0.0)
	# Await on the same time-scaled idle clock used by the authored Timer nodes,
	# so the assertion remains deterministic under editor/test time-scale changes.
	await create_timer(0.42, true, false, false).timeout
	await process_frame
	var completed_tick_count := (
		fixture.combat_query_call_count - query_count_before
	)
	_expect(
		completed_tick_count == 3,
		"完整3秒雨幕必须恰好结算3个每秒tick，结束边界不得产生第4个tick；实际为%d。"
		% completed_tick_count
	)
	_expect(
		not tower.rain_active
		and tower.rain_tick_timer.is_stopped()
		and tower.rain_end_timer.is_stopped(),
		(
			"完整雨幕结束后必须清除活动状态，并停止tick与结束计时器；"
			+ "active=%s tick_stopped=%s end_stopped=%s。"
		) % [
			str(tower.rain_active),
			str(tower.rain_tick_timer.is_stopped()),
			str(tower.rain_end_timer.is_stopped()),
		]
	)
	tower.queue_free()
	await process_frame


func _test_proxy_runtime_state_preserves_packet_aged_phase() -> void:
	var footprint_cells: Array[Vector2i] = [
		Vector2i.ZERO,
		Vector2i.RIGHT,
		Vector2i.DOWN,
		Vector2i.ONE,
	]
	var constructing_proxy := HYDRANGEA_SCENE.instantiate() as HydrangeaRainTower
	fixture.add_child(constructing_proxy)
	constructing_proxy.setup(
		HYDRANGEA_CONFIG,
		null,
		footprint_cells,
		true,
		-1,
		0,
		-1,
		true
	)
	var transmitted_cycle_elapsed := 4.0
	var packet_age_seconds := 0.35
	var packet_aged_cycle_elapsed := (
		transmitted_cycle_elapsed + packet_age_seconds
	)
	constructing_proxy.apply_multiplayer_runtime_state(
		{
			"schema": HydrangeaRainTower.RUNTIME_STATE_SCHEMA,
			"cycle_elapsed_seconds": packet_aged_cycle_elapsed,
			"rain_active": false,
			"rain_action_id": 2,
		},
		0.0
	)
	_expect(
		not constructing_proxy.is_operational
		and is_equal_approx(
			constructing_proxy.pending_proxy_cycle_elapsed_seconds,
			packet_aged_cycle_elapsed
		)
		and constructing_proxy.cycle_timer.is_stopped(),
		"未operational的代理必须缓存已计入包龄的cycle_elapsed，且不得提前启动周期计时器。"
	)
	constructing_proxy.call("_stop_construction_tween")
	constructing_proxy.call("_finish_construction", false)
	var retained_cycle_elapsed := (
		float(constructing_proxy.call("_now_seconds"))
		- constructing_proxy.cycle_started_at_seconds
	)
	_expect(
		constructing_proxy.is_operational
		and constructing_proxy.pending_proxy_cycle_elapsed_seconds < 0.0
		and absf(retained_cycle_elapsed - packet_aged_cycle_elapsed) < 0.05
		and not constructing_proxy.cycle_timer.is_stopped()
		and absf(
			constructing_proxy.cycle_timer.time_left
			- (
				HYDRANGEA_CONFIG.rain_interval_seconds
				- packet_aged_cycle_elapsed
			)
		) < 0.05,
		"代理转为operational时必须消费缓存，并从含包龄的相位继续而非重置为新10秒周期。"
	)
	constructing_proxy.queue_free()
	await process_frame

	var boundary_proxy := HYDRANGEA_SCENE.instantiate() as HydrangeaRainTower
	fixture.add_child(boundary_proxy)
	boundary_proxy.setup(
		HYDRANGEA_CONFIG,
		null,
		footprint_cells,
		true
	)
	var corrected_cycle_elapsed := 10.05
	boundary_proxy.apply_multiplayer_runtime_state(
		{
			"schema": HydrangeaRainTower.RUNTIME_STATE_SCHEMA,
			"cycle_elapsed_seconds": corrected_cycle_elapsed,
			"rain_active": false,
			"rain_action_id": 7,
		},
		0.0
	)
	var inferred_rain_elapsed := (
		float(boundary_proxy.call("_now_seconds"))
		- boundary_proxy.rain_started_at_seconds
	)
	_expect(
		boundary_proxy.rain_active
		and boundary_proxy.rain_action_id == 8
		and absf(inferred_rain_elapsed - 0.05) < 0.05
		and not boundary_proxy.rain_end_timer.is_stopped()
		and absf(
			boundary_proxy.rain_end_timer.time_left
			- (HYDRANGEA_CONFIG.rain_duration_seconds - 0.05)
		) < 0.05,
		"9.95秒非雨状态加0.1秒包龄必须推演为当前雨幕已进行0.05秒，不能漏掉跨周期事件。"
	)
	boundary_proxy.queue_free()
	await process_frame


func _apply_attack_reduction(
	enemy: Enemy,
	source_id: int,
	duration: float
) -> void:
	enemy.apply_collectible_status(
		HydrangeaRainTower.ATTACK_REDUCTION_STATUS_ID,
		source_id,
		duration,
		0,
		0.5,
		EnemyConfig.DamageType.MAGIC,
		1.0,
		0,
		1.0,
		EXPECTED_ATTACK_MULTIPLIER
	)


func _expect(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)
