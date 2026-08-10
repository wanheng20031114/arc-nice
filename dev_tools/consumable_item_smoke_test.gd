extends SceneTree

const PLAYER_SCENE := preload("res://scene/player/weishidaier/player_weishidaier.tscn")
const PICKUP_SCENE := preload("res://scene/combat/pickups/pickup.tscn")
const PROFILE_PANEL_SCENE := preload(
	"res://scene/game_modes/standard/ui/standard_player_profile_panel.tscn"
)
const OAK_WAREHOUSE_PANEL_SCENE := preload(
	"res://scene/game_modes/tower_defense/economy/warehouse/oak_warehouse_panel.tscn"
)
const SPEED_BOOTS := preload(
	"res://resources/config/pickup_triggered_items/speed_boots.tres"
)
const RAPID_MAGAZINE := preload(
	"res://resources/config/pickup_triggered_items/rapid_magazine.tres"
)
const SNOW_WOLF_POJUN := preload(
	"res://resources/config/pickup_triggered_items/snow_wolf_pojun.tres"
)
const TENPURA := preload(
	"res://resources/config/pickup_triggered_items/tenpura.tres"
)
const HEALING_POTION := preload(
	"res://resources/config/consumables/healing_potion.tres"
)
const LARGE_HEALING_POTION := preload(
	"res://resources/config/consumables/large_healing_potion.tres"
)
const ROCK_POTION := preload(
	"res://resources/config/consumables/rock_potion.tres"
)
const LARGE_ROCK_POTION := preload(
	"res://resources/config/consumables/large_rock_potion.tres"
)
const PHYSICAL_RING := preload(
	"res://resources/config/collectibles/collectible_physical_ring.tres"
)

var failures: Array[String] = []
var test_root: Node2D
var run_state: RunStateStore


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	test_root = Node2D.new()
	test_root.name = "ConsumableItemSmokeTest"
	root.add_child(test_root)
	current_scene = test_root
	run_state = root.get_node("RunState") as RunStateStore

	_test_config_contract()
	await _test_world_pickup_split_and_full_inventory()
	await _test_healing_and_use_restrictions()
	await _test_rock_potion_override_and_lifetime()
	await _test_generic_use_gate_and_ui_categories()

	current_scene = null
	test_root.queue_free()
	for _cleanup_frame in range(8):
		await process_frame
		await physics_frame
	if failures.is_empty():
		print("CONSUMABLE_ITEM_SMOKE_TEST_OK")
		quit()
		return
	for failure in failures:
		push_error(failure)
	quit(1)


func _test_config_contract() -> void:
	_expect(
		PickupConfig.PickupType.CONSUMABLE == 4
		and PickupConfig.PickupType.COLLECTIBLE == 5
		and PickupConfig.PickupType.MATERIAL == 6
		and PickupConfig.PickupType.BUILDING == 7,
		"消耗品改名不得改变已序列化的4/5/6/7分类数值。"
	)
	var triggered_items: Array[PickupConfig] = [
		SPEED_BOOTS,
		RAPID_MAGAZINE,
		SNOW_WOLF_POJUN,
		TENPURA,
	]
	for item in triggered_items:
		_expect(
			item.is_pickup_triggered_item() and not item.is_consumable_item(),
			"%s 必须属于即时拾取触发分类。" % item.display_name
		)

	var consumables: Array[PickupConfig] = [
		HEALING_POTION,
		LARGE_HEALING_POTION,
		ROCK_POTION,
		LARGE_ROCK_POTION,
	]
	for item in consumables:
		_expect(
			item.is_consumable_item()
			and not item.is_pickup_triggered_item()
			and item.can_store_in_inventory
			and item.stackable
			and item.inventory_stack_limit == 999,
			"%s 必须是上限999的可堆叠消耗品。" % item.display_name
		)
	_expect(
		HEALING_POTION.heal_amount == 20
		and LARGE_HEALING_POTION.heal_amount == 50,
		"大小治疗血瓶必须分别回复20和50点生命。"
	)
	_expect(
		ROCK_POTION.potion_physical_defense_bonus == 15
		and LARGE_ROCK_POTION.potion_physical_defense_bonus == 45
		and is_equal_approx(ROCK_POTION.duration, 10.0)
		and is_equal_approx(LARGE_ROCK_POTION.duration, 10.0),
		"大小岩石药水必须分别提供15/45物防且持续10秒。"
	)
	_test_icon_contract()


func _test_icon_contract() -> void:
	var icon_cases := [
		{
			"item": HEALING_POTION,
			"path": "res://resources/texture/consumables/healing_potion.png",
			"bbox": Rect2i(5, 1, 22, 30),
			"scale": Vector2(0.5, 0.5),
		},
		{
			"item": LARGE_HEALING_POTION,
			"path": "res://resources/texture/consumables/large_healing_potion.png",
			"bbox": Rect2i(3, 1, 26, 30),
			"scale": Vector2(0.625, 0.625),
		},
		{
			"item": ROCK_POTION,
			"path": "res://resources/texture/consumables/rock_potion.png",
			"bbox": Rect2i(6, 1, 20, 30),
			"scale": Vector2(0.5, 0.5),
		},
		{
			"item": LARGE_ROCK_POTION,
			"path": "res://resources/texture/consumables/large_rock_potion.png",
			"bbox": Rect2i(3, 1, 26, 30),
			"scale": Vector2(0.625, 0.625),
		},
	]
	for icon_case in icon_cases:
		var item := icon_case["item"] as PickupConfig
		var image := Image.load_from_file(
			ProjectSettings.globalize_path(str(icon_case["path"]))
		)
		_expect(
			image != null
			and image.get_size() == Vector2i(32, 32)
			and image.get_used_rect() == icon_case["bbox"]
			and item.icon_scale == icon_case["scale"],
			"%s 必须保持批准的32x32轮廓、留白与世界缩放。" % item.display_name
		)
		if image == null:
			continue
		var has_partial_alpha := false
		var has_dirty_transparent_rgb := false
		for y in image.get_height():
			for x in image.get_width():
				var pixel := image.get_pixel(x, y)
				has_partial_alpha = (
					has_partial_alpha
					or (pixel.a > 0.0 and pixel.a < 1.0)
				)
				if is_zero_approx(pixel.a):
					has_dirty_transparent_rgb = (
						has_dirty_transparent_rgb
						or not Vector3(pixel.r, pixel.g, pixel.b).is_zero_approx()
					)
		_expect(
			not has_partial_alpha and not has_dirty_transparent_rgb,
			"%s 必须使用硬透明边，透明像素不得残留色键。" % item.display_name
		)


func _test_world_pickup_split_and_full_inventory() -> void:
	run_state.begin_new_run(&"weishidaier", false)
	var player := await _spawn_player(Vector2(1000.0, 0.0))
	player.current_health = maxi(player.max_health - 30, 1)
	var health_before := player.current_health
	var potion_pickup := _spawn_world_pickup(HEALING_POTION)
	var potion_applied_immediately: Array[bool] = []
	potion_pickup.consumed.connect(
		func(_pickup: Pickup, _peer_id: int, applied_immediately: bool) -> void:
			potion_applied_immediately.append(applied_immediately)
	)
	potion_pickup.call("_on_body_entered", player)
	_expect(
		player.current_health == health_before
		and run_state.get_inventory_item_total(HEALING_POTION) == 1
		and potion_applied_immediately == [false],
		"世界中的治疗血瓶即使玩家受伤也只能收入背包，不能碰触即治疗。"
	)
	await process_frame

	var speed_pickup := _spawn_world_pickup(SPEED_BOOTS)
	var speed_applied_immediately: Array[bool] = []
	speed_pickup.consumed.connect(
		func(_pickup: Pickup, _peer_id: int, applied_immediately: bool) -> void:
			speed_applied_immediately.append(applied_immediately)
	)
	speed_pickup.call("_on_body_entered", player)
	_expect(
		speed_applied_immediately == [true]
		and player.speed_buff_time_left > 0.0
		and run_state.get_inventory_item_total(SPEED_BOOTS) == 0,
		"即时拾取触发道具必须立刻生效且不得进入背包。"
	)
	await process_frame

	run_state.begin_new_run(&"weishidaier", false)
	for filler_index in range(RunStateStore.INVENTORY_CAPACITY):
		var filler := PickupConfig.new()
		filler.pickup_type = PickupConfig.PickupType.MATERIAL
		filler.display_name = "占位物资%d" % filler_index
		filler.can_store_in_inventory = true
		_expect(run_state.try_add_item(filler), "背包满测试必须成功填满所有槽位。")
	player.current_health = maxi(player.max_health - 20, 1)
	health_before = player.current_health
	var blocked_pickup := _spawn_world_pickup(HEALING_POTION)
	blocked_pickup.call("_on_body_entered", player)
	_expect(
		blocked_pickup.lifecycle == Pickup.Lifecycle.AVAILABLE
		and not blocked_pickup.is_queued_for_deletion()
		and player.current_health == health_before,
		"背包已满时消耗品必须留在地面且不能偷偷应用效果。"
	)
	blocked_pickup.queue_free()
	_stop_audio_players(player)
	player.queue_free()
	await process_frame
	await physics_frame


func _test_healing_and_use_restrictions() -> void:
	run_state.begin_new_run(&"weishidaier", false)
	var player := await _spawn_player()
	_expect(
		run_state.try_add_item_count(HEALING_POTION, 2)
		and run_state.try_add_item_count(LARGE_HEALING_POTION, 1),
		"治疗血瓶使用测试必须建立两个药水堆叠。"
	)

	player.current_health = maxi(player.max_health - 60, 1)
	var health_before := player.current_health
	_expect(run_state.try_use_item(0, player), "受伤且存活时必须能使用治疗血瓶。")
	_expect(
		player.current_health == mini(health_before + 20, player.max_health)
		and run_state.get_item_count(0) == 1,
		"小治疗血瓶必须只回复20点并只扣除堆叠中的一瓶。"
	)

	player.current_health = maxi(player.max_health - 80, 1)
	health_before = player.current_health
	_expect(run_state.try_use_item(1, player), "受伤且存活时必须能使用大号治疗血瓶。")
	_expect(
		player.current_health == mini(health_before + 50, player.max_health)
		and run_state.get_item(1) == null,
		"大号治疗血瓶必须回复50点并在最后一瓶用完后清空槽位。"
	)

	player.current_health = player.max_health
	var count_before := run_state.get_item_count(0)
	var revision_before := run_state.get_inventory_revision()
	_expect(not run_state.try_use_item(0, player), "满血时必须拒绝治疗血瓶。")
	_expect(
		run_state.get_item_count(0) == count_before
		and run_state.get_inventory_revision() == revision_before,
		"满血拒绝使用时不得扣除物品或推进背包revision。"
	)

	player.apply_multiplayer_death_state()
	_expect(not run_state.try_use_item(0, player), "死亡时必须拒绝饮用消耗品。")
	_expect(run_state.get_item_count(0) == count_before, "死亡拒绝使用时不得扣除物品。")
	player.revive_multiplayer(player.global_position, player.max_health - 10)
	player.set_world_movement_mode(true, false)
	_expect(not run_state.try_use_item(0, player), "路线移动模式必须拒绝饮用消耗品。")
	_expect(run_state.get_item_count(0) == count_before, "路线模式拒绝使用时不得扣除物品。")
	player.set_world_movement_mode(false, false)
	_stop_audio_players(player)
	player.queue_free()
	await process_frame
	await physics_frame


func _test_rock_potion_override_and_lifetime() -> void:
	run_state.begin_new_run(&"weishidaier", false)
	var player := await _spawn_player()
	_expect(run_state.try_add_item(PHYSICAL_RING), "物防组合测试必须加入物理戒指。")
	player.set_research_temporary_physical_defense_bonus(7)
	var defense_without_potion := player.physical_defense
	var magic_defense_before := player.magic_defense
	_expect(
		run_state.try_add_item_count(ROCK_POTION, 2)
		and run_state.try_add_item(LARGE_ROCK_POTION),
		"岩石药水覆盖测试必须建立大小药水堆叠。"
	)

	_expect(run_state.try_use_item(1, player), "必须能饮用小岩石药水。")
	_expect(
		player.physical_defense == defense_without_potion + 15
		and player.magic_defense == magic_defense_before
		and player.potion_physical_defense_bonus == 15
		and is_equal_approx(player.potion_physical_defense_time_left, 10.0),
		"小岩石药水必须独立增加15物防、保持魔防不变并从10秒开始。"
	)
	player.call("_update_pickup_effects", 4.0)
	_expect(
		is_equal_approx(player.potion_physical_defense_time_left, 6.0),
		"岩石药水持续时间必须按模拟时间倒计时。"
	)

	_expect(run_state.try_use_item(2, player), "必须能用大岩石药水覆盖小药水。")
	_expect(
		player.physical_defense == defense_without_potion + 45
		and player.potion_physical_defense_bonus == 45
		and is_equal_approx(player.potion_physical_defense_time_left, 10.0),
		"大岩石药水后喝时必须覆盖为45物防并刷新为10秒，不能叠加。"
	)
	player.call("_update_pickup_effects", 2.0)
	_expect(run_state.try_use_item(1, player), "必须能用小岩石药水反向覆盖大药水。")
	_expect(
		player.physical_defense == defense_without_potion + 15
		and player.potion_physical_defense_bonus == 15
		and is_equal_approx(player.potion_physical_defense_time_left, 10.0),
		"小药水后喝时必须降回15物防并刷新时间。"
	)
	var replacement_player := await _spawn_player()
	_expect(
		replacement_player.potion_physical_defense_bonus == 0
		and is_zero_approx(
			replacement_player.potion_physical_defense_time_left
		),
		"换场或重连创建的新Player实例不得恢复上一实例的药水状态。"
	)
	_stop_audio_players(replacement_player)
	replacement_player.queue_free()
	await process_frame
	await physics_frame

	player.apply_multiplayer_death_state()
	player.call("_update_pickup_effects", 4.0)
	_expect(
		player.is_dead
		and player.physical_defense == defense_without_potion + 15
		and is_equal_approx(player.potion_physical_defense_time_left, 6.0),
		"死亡期间岩石药水必须继续倒计时，但未到期前仍保留加成。"
	)
	player.revive_multiplayer(player.global_position, 1)
	_expect(
		player.physical_defense == defense_without_potion + 15
		and is_equal_approx(player.potion_physical_defense_time_left, 6.0),
		"复活不能清空或重置岩石药水的剩余效果。"
	)
	player.call("_update_pickup_effects", 6.1)
	_expect(
		player.physical_defense == defense_without_potion
		and player.magic_defense == magic_defense_before
		and player.potion_physical_defense_bonus == 0
		and is_zero_approx(player.potion_physical_defense_time_left),
		"10秒到期后只应移除药水物防，研究、收藏品和魔防必须保持。"
	)
	_stop_audio_players(player)
	player.queue_free()
	await process_frame
	await physics_frame


func _test_generic_use_gate_and_ui_categories() -> void:
	run_state.begin_new_run(&"weishidaier", false)
	var player := await _spawn_player()
	var storable_triggered_item := SPEED_BOOTS.duplicate() as PickupConfig
	storable_triggered_item.can_store_in_inventory = true
	var building := PickupConfig.new()
	building.pickup_type = PickupConfig.PickupType.BUILDING
	building.display_name = "测试建筑"
	building.can_store_in_inventory = true
	_expect(
		run_state.try_add_item(storable_triggered_item)
		and run_state.try_add_item(building),
		"通用使用入口分类测试必须建立即时道具与建筑槽位。"
	)
	var revision_before := run_state.get_inventory_revision()
	_expect(
		not run_state.try_use_item(0, player)
		and not run_state.try_use_item(1, player)
		and run_state.get_inventory_revision() == revision_before,
		"背包通用使用入口只能消费CONSUMABLE，不能使用即时道具或建筑。"
	)

	var profile := PROFILE_PANEL_SCENE.instantiate() as StandardPlayerProfilePanel
	var warehouse_panel := OAK_WAREHOUSE_PANEL_SCENE.instantiate() as OakWarehousePanel
	test_root.add_child(profile)
	test_root.add_child(warehouse_panel)
	await process_frame
	_expect(
		profile.inventory_view.call("_get_item_type_label", HEALING_POTION) == "消耗品",
		"玩家背包详情必须把药水标记为消耗品。"
	)
	_expect(
		warehouse_panel.call("_is_consumable_item", HEALING_POTION)
		and not warehouse_panel.call("_is_consumable_item", SPEED_BOOTS)
		and not warehouse_panel.call("_is_consumable_item", building)
		and warehouse_panel.call("_is_player_inventory_action_item", building),
		"橡木仓库必须只把CONSUMABLE当消耗品，同时保留建筑的独立建造操作。"
	)
	profile.queue_free()
	warehouse_panel.queue_free()
	_stop_audio_players(player)
	player.queue_free()
	await process_frame
	await physics_frame


func _spawn_player(position: Vector2 = Vector2.ZERO) -> Player:
	var player := PLAYER_SCENE.instantiate() as Player
	player.position = position
	test_root.add_child(player)
	await process_frame
	await physics_frame
	player.set_physics_process(false)
	return player


func _spawn_world_pickup(config: PickupConfig) -> Pickup:
	var pickup := PICKUP_SCENE.instantiate() as Pickup
	pickup.config = config
	test_root.add_child(pickup)
	return pickup


func _stop_audio_players(node: Node) -> void:
	if node is AudioStreamPlayer:
		(node as AudioStreamPlayer).stop()
	elif node is AudioStreamPlayer2D:
		(node as AudioStreamPlayer2D).stop()
	for child in node.get_children():
		_stop_audio_players(child)


func _expect(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)
