extends SceneTree

const PLAYER_SCENE := preload("res://scene/player/weishidaier/player_weishidaier.tscn")
const PLAYER_TEST_RUNTIME := preload(
	"res://dev_tools/player_test_combat_runtime.gd"
)
const SPEED_BOOTS: PickupConfig = preload(
	"res://resources/config/pickup_triggered_items/speed_boots.tres"
)
const RAPID_MAGAZINE: PickupConfig = preload(
	"res://resources/config/pickup_triggered_items/rapid_magazine.tres"
)
const TENPURA: PickupConfig = preload(
	"res://resources/config/pickup_triggered_items/tenpura.tres"
)
const SKILL_CHARGE_BATTERY: PickupConfig = preload(
	"res://resources/config/consumables/skill_charge_battery.tres"
)
const LARGE_SKILL_CHARGE_BATTERY: PickupConfig = preload(
	"res://resources/config/consumables/large_skill_charge_battery.tres"
)
const MAGIC_RESISTANCE_POTION: PickupConfig = preload(
	"res://resources/config/consumables/magic_resistance_potion.tres"
)
const LARGE_MAGIC_RESISTANCE_POTION: PickupConfig = preload(
	"res://resources/config/consumables/large_magic_resistance_potion.tres"
)
const REGENERATION_POTION: PickupConfig = preload(
	"res://resources/config/consumables/regeneration_potion.tres"
)
const LARGE_REGENERATION_POTION: PickupConfig = preload(
	"res://resources/config/consumables/large_regeneration_potion.tres"
)
const GUARDIAN_MIXTURE: PickupConfig = preload(
	"res://resources/config/consumables/guardian_mixture.tres"
)
const BATTLE_SPIRIT_POTION: PickupConfig = preload(
	"res://resources/config/consumables/battle_spirit_potion.tres"
)
const FOCUS_POTION: PickupConfig = preload(
	"res://resources/config/consumables/focus_potion.tres"
)
const WINDWALK_POTION: PickupConfig = preload(
	"res://resources/config/consumables/windwalk_potion.tres"
)
const PHANTOM_POTION: PickupConfig = preload(
	"res://resources/config/consumables/phantom_potion.tres"
)
const VOID_BATTERY: PickupConfig = preload(
	"res://resources/config/consumables/void_battery.tres"
)
const EXTERNAL_REDUCTION_SOURCE := 9127

var failures: Array[String] = []
var test_root: Node2D
var run_state: RunStateStore


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	test_root = Node2D.new()
	test_root.name = "ExpandedConsumableEffectsSmokeTest"
	root.add_child(test_root)
	current_scene = test_root
	run_state = root.get_node("RunState") as RunStateStore

	_test_config_contract()
	await _test_skill_charge_batteries()
	await _test_magic_resistance_and_regeneration()
	await _test_independent_combat_potions()
	await _test_void_battery_transaction()

	current_scene = null
	test_root.queue_free()
	for _cleanup_frame in range(6):
		await process_frame
		await physics_frame
	if failures.is_empty():
		print("EXPANDED_CONSUMABLE_EFFECTS_SMOKE_TEST_OK")
		quit()
		return
	for failure in failures:
		push_error(failure)
	quit(1)


func _test_config_contract() -> void:
	var consumables: Array[PickupConfig] = [
		SKILL_CHARGE_BATTERY,
		LARGE_SKILL_CHARGE_BATTERY,
		MAGIC_RESISTANCE_POTION,
		LARGE_MAGIC_RESISTANCE_POTION,
		REGENERATION_POTION,
		LARGE_REGENERATION_POTION,
		GUARDIAN_MIXTURE,
		BATTLE_SPIRIT_POTION,
		FOCUS_POTION,
		WINDWALK_POTION,
		PHANTOM_POTION,
		VOID_BATTERY,
	]
	var expected_names: Array[String] = [
		"蓝晶技力电池",
		"大型蓝晶技力电池",
		"紫晶法抗药水",
		"大型紫晶法抗药水",
		"凝胶再生剂",
		"大型凝胶再生剂",
		"守护合剂",
		"战意药水",
		"专注药水",
		"风行药水",
		"幻影药剂",
		"虚空电池",
	]
	var expected_world_scales: Array[Vector2] = [
		Vector2(0.5, 0.5),
		Vector2(0.625, 0.625),
		Vector2(0.5, 0.5),
		Vector2(0.625, 0.625),
		Vector2(0.5, 0.5),
		Vector2(0.625, 0.625),
		Vector2(0.5, 0.5),
		Vector2(0.5, 0.5),
		Vector2(0.5, 0.5),
		Vector2(0.5, 0.5),
		Vector2(0.5, 0.5),
		Vector2(0.5, 0.5),
	]
	for item_index in consumables.size():
		var item := consumables[item_index]
		var icon_atlas := item.icon_texture as AtlasTexture if item != null else null
		_expect(
			item != null
			and item.display_name == expected_names[item_index]
			and item.is_consumable_item()
			and item.can_store_in_inventory
			and item.stackable
			and item.inventory_stack_limit == 999,
			"新增消耗品必须保持锁定名称、分类与999堆叠契约：%s"
			% expected_names[item_index]
		)
		_expect(
			icon_atlas != null
			and icon_atlas.atlas != null
			and icon_atlas.region == Rect2(0, 0, 32, 32)
			and item.icon_scale == expected_world_scales[item_index],
			"新增消耗品必须使用完整32×32图集和锁定的世界缩放：%s"
			% expected_names[item_index]
		)
	_expect(
		is_equal_approx(SKILL_CHARGE_BATTERY.skill_charge_restore_amount, 3.0)
		and is_equal_approx(
			LARGE_SKILL_CHARGE_BATTERY.skill_charge_restore_amount,
			5.0
		),
		"大小蓝晶技力电池必须分别恢复3/5点技力。"
	)
	_expect(
		MAGIC_RESISTANCE_POTION.potion_magic_defense_bonus == 15
		and LARGE_MAGIC_RESISTANCE_POTION.potion_magic_defense_bonus == 30
		and is_equal_approx(MAGIC_RESISTANCE_POTION.duration, 10.0)
		and is_equal_approx(LARGE_MAGIC_RESISTANCE_POTION.duration, 10.0),
		"大小紫晶法抗药水必须分别提供15/30魔防并持续10秒。"
	)
	_expect(
		is_equal_approx(REGENERATION_POTION.potion_regeneration_per_second, 4.0)
		and is_equal_approx(REGENERATION_POTION.duration, 6.0)
		and is_equal_approx(
			LARGE_REGENERATION_POTION.potion_regeneration_per_second,
			6.0
		)
		and is_equal_approx(LARGE_REGENERATION_POTION.duration, 8.0),
		"大小凝胶再生剂必须保持4/s×6秒与6/s×8秒。"
	)
	_expect(
		is_equal_approx(GUARDIAN_MIXTURE.potion_damage_reduction, 0.2)
		and is_equal_approx(GUARDIAN_MIXTURE.duration, 8.0)
		and is_equal_approx(
			BATTLE_SPIRIT_POTION.potion_attack_damage_multiplier,
			1.2
		)
		and is_equal_approx(FOCUS_POTION.potion_fire_rate_multiplier, 1.3)
		and is_equal_approx(WINDWALK_POTION.potion_move_speed_multiplier, 1.2)
		and is_equal_approx(PHANTOM_POTION.potion_dodge_chance_bonus, 0.1)
		and VOID_BATTERY.grants_next_skill_free,
		"六种独立战斗药剂与虚空电池必须保持锁定数值。"
	)
	_expect(
		BATTLE_SPIRIT_POTION.description == "使用后攻击力提升20%，持续8秒。"
		and not BATTLE_SPIRIT_POTION.description.contains("×1.20"),
		"战意药水面向玩家必须使用锁定的攻击力提升20%文案。"
	)


func _test_skill_charge_batteries() -> void:
	run_state.begin_new_run(&"weishidaier", false)
	var player := await _spawn_player()
	player.skill1_unlocked = true
	player.skill1_charge = 1.0
	_expect(
		run_state.try_add_item(SKILL_CHARGE_BATTERY)
		and run_state.try_add_item(LARGE_SKILL_CHARGE_BATTERY),
		"技力电池测试必须建立大小电池。"
	)
	var small_slot := _find_local_item_slot(SKILL_CHARGE_BATTERY)
	var large_slot := _find_local_item_slot(LARGE_SKILL_CHARGE_BATTERY)
	_expect(run_state.try_use_item(small_slot, player), "未满技力时必须能使用小电池。")
	_expect(
		is_equal_approx(player.skill1_charge, 4.0),
		"小电池必须精确恢复3点技力。"
	)
	_expect(run_state.try_use_item(large_slot, player), "未满技力时必须能使用大电池。")
	_expect(
		is_equal_approx(player.skill1_charge, 9.0),
		"大电池必须在现有技力上精确恢复5点。"
	)

	_expect(run_state.try_add_item(SKILL_CHARGE_BATTERY), "满技力拒绝测试必须补充电池。")
	small_slot = _find_local_item_slot(SKILL_CHARGE_BATTERY)
	player.skill1_charge = player.skill1_charge_duration
	var revision_before := run_state.get_inventory_revision()
	var count_before := run_state.get_item_count(small_slot)
	_expect(not run_state.try_use_item(small_slot, player), "满技力必须拒绝技力电池。")
	_expect(
		run_state.get_inventory_revision() == revision_before
		and run_state.get_item_count(small_slot) == count_before,
		"满技力拒绝电池时不得扣物品或推进revision。"
	)
	player.skill1_unlocked = false
	player.skill1_charge = 0.0
	_expect(not run_state.try_use_item(small_slot, player), "技能未解锁时必须拒绝技力电池。")
	_expect(run_state.get_inventory_revision() == revision_before, "技能锁定拒绝不得推进revision。")
	_stop_audio_players(player)
	player.queue_free()
	await process_frame
	await physics_frame


func _test_magic_resistance_and_regeneration() -> void:
	var player := await _spawn_player()
	var base_magic_defense := player.magic_defense
	var base_physical_defense := player.physical_defense
	_expect(player.apply_pickup(MAGIC_RESISTANCE_POTION), "必须能饮用小法抗药水。")
	_expect(
		player.magic_defense == base_magic_defense + 15
		and player.physical_defense == base_physical_defense
		and is_equal_approx(player.potion_magic_defense_time_left, 10.0),
		"小法抗药水必须只增加15魔防。"
	)
	player.call("_update_potion_effects", 4.0)
	_expect(player.apply_pickup(LARGE_MAGIC_RESISTANCE_POTION), "大法抗药水必须能覆盖小瓶。")
	_expect(
		player.magic_defense == base_magic_defense + 30
		and is_equal_approx(player.potion_magic_defense_time_left, 10.0),
		"大法抗后喝必须覆盖为30并刷新10秒，不能叠加。"
	)
	_expect(player.apply_pickup(MAGIC_RESISTANCE_POTION), "小法抗必须能反向覆盖大瓶。")
	_expect(
		player.magic_defense == base_magic_defense + 15
		and is_equal_approx(player.potion_magic_defense_time_left, 10.0),
		"小法抗后喝必须降回15并刷新10秒。"
	)
	player.call("_update_potion_effects", 10.1)
	_expect(
		player.magic_defense == base_magic_defense
		and player.physical_defense == base_physical_defense,
		"法抗药水到期只能移除药水魔防。"
	)

	player.current_health = 1
	_expect(player.apply_pickup(REGENERATION_POTION), "必须能使用小再生剂。")
	player.call("_update_potion_effects", 2.5)
	_expect(
		player.current_health == 11
		and is_equal_approx(player.potion_regeneration_time_left, 3.5),
		"小再生剂2.5秒必须回复10点且剩余3.5秒。"
	)
	player.current_health = 1
	_expect(player.apply_pickup(LARGE_REGENERATION_POTION), "大再生剂必须覆盖小瓶。")
	_expect(
		is_zero_approx(player.potion_regeneration_heal_accumulator)
		and is_equal_approx(player.potion_regeneration_time_left, 8.0),
		"同族再生剂覆盖时必须清空旧小数进度并刷新持续时间。"
	)
	player.call("_update_potion_effects", 8.0)
	_expect(
		player.current_health == 49
		and is_zero_approx(player.potion_regeneration_time_left),
		"大再生剂完整8秒必须回复48点。"
	)

	player.current_health = 1
	_expect(player.apply_pickup(LARGE_REGENERATION_POTION), "死亡生命周期测试必须启动再生。")
	player.apply_multiplayer_death_state()
	player.call("_update_potion_effects", 2.0)
	_expect(
		player.is_dead
		and is_equal_approx(player.potion_regeneration_time_left, 6.0),
		"死亡期间再生持续时间必须继续倒计时且不能复活玩家。"
	)
	player.revive_multiplayer(player.global_position, 1)
	player.call("_update_potion_effects", 1.0)
	_expect(
		player.current_health == 7
		and is_equal_approx(player.potion_regeneration_time_left, 5.0),
		"复活后必须保留再生剩余时间并按6/s继续回复。"
	)
	_stop_audio_players(player)
	player.queue_free()
	await process_frame
	await physics_frame


func _test_independent_combat_potions() -> void:
	var player := await _spawn_player()
	var base_dodge := player.dodge_chance
	_expect(player.apply_pickup(TENPURA), "独立攻击状态测试必须先应用天妇罗。")
	var triggered_attack := player.attack_damage
	_expect(player.apply_pickup(BATTLE_SPIRIT_POTION), "必须能饮用战意药水。")
	_expect(
		is_equal_approx(player.temporary_attack_damage_multiplier, 1.1)
		and is_equal_approx(player.potion_attack_damage_multiplier, 1.2)
		and player.attack_damage > triggered_attack,
		"战意药水必须与天妇罗独立相乘，不能覆盖即时拾取状态。"
	)
	_expect(player.apply_pickup(RAPID_MAGAZINE), "独立攻速状态测试必须先应用急速弹匣。")
	_expect(player.apply_pickup(FOCUS_POTION), "必须能饮用专注药水。")
	_expect(
		is_equal_approx(player.rapid_fire_rate_multiplier, 2.0)
		and is_equal_approx(player.potion_fire_rate_multiplier, 1.3)
		and is_equal_approx(
			float(player.call("_get_effective_fire_rate_multiplier")),
			2.6
		),
		"专注药水必须与急速弹匣独立相乘。"
	)
	_expect(player.apply_pickup(SPEED_BOOTS), "独立移速状态测试必须先应用加速鞋。")
	_expect(player.apply_pickup(WINDWALK_POTION), "必须能饮用风行药水。")
	_expect(
		is_equal_approx(player.current_move_speed_multiplier, 1.25)
		and is_equal_approx(player.potion_move_speed_multiplier, 1.2)
		and is_equal_approx(player.get_authoritative_move_speed_multiplier(), 1.5),
		"风行药水必须与加速鞋独立相乘。"
	)
	_expect(player.apply_pickup(PHANTOM_POTION), "必须能饮用幻影药剂。")
	_expect(
		is_equal_approx(player.get_effective_dodge_chance(), base_dodge + 0.1),
		"幻影药剂必须临时增加10个百分点闪避。"
	)
	_expect(player.apply_pickup(GUARDIAN_MIXTURE), "必须能饮用守护合剂。")
	var request := DamageRequest.new(20, EnemyConfig.DamageType.PHYSICAL)
	var profile := player.call("_create_damage_target_profile", request) as DamageTargetProfile
	_expect(
		profile != null and is_equal_approx(profile.post_mitigation_multiplier, 0.8),
		"守护合剂必须提供20%全伤害减免。"
	)
	player.add_damage_reduction_modifier(EXTERNAL_REDUCTION_SOURCE, 0.5)
	profile = player.call("_create_damage_target_profile", request) as DamageTargetProfile
	_expect(
		profile != null and is_equal_approx(profile.post_mitigation_multiplier, 0.5),
		"守护合剂与50%外部减伤同时存在时必须只取50%。"
	)

	player.call("_update_potion_effects", 8.1)
	_expect(
		is_equal_approx(player.temporary_attack_damage_multiplier, 1.1)
		and is_equal_approx(player.potion_attack_damage_multiplier, 1.0)
		and is_equal_approx(player.rapid_fire_rate_multiplier, 2.0)
		and is_equal_approx(player.potion_fire_rate_multiplier, 1.0)
		and is_zero_approx(player.potion_dodge_chance_bonus)
		and is_zero_approx(player.potion_damage_reduction),
		"8秒药水到期必须只清除各自药水状态，不触碰即时拾取状态。"
	)
	_expect(
		is_equal_approx(player.potion_move_speed_time_left, 1.9)
		and is_equal_approx(player.get_authoritative_move_speed_multiplier(), 1.5),
		"10秒风行药水在8.1秒时必须仍与加速鞋共同生效。"
	)
	player.call("_update_potion_effects", 2.0)
	_expect(
		is_equal_approx(player.current_move_speed_multiplier, 1.25)
		and is_equal_approx(player.potion_move_speed_multiplier, 1.0)
		and is_equal_approx(player.get_authoritative_move_speed_multiplier(), 1.25),
		"风行到期后必须保留加速鞋倍率。"
	)
	_stop_audio_players(player)
	player.queue_free()
	await process_frame
	await physics_frame


func _test_void_battery_transaction() -> void:
	run_state.begin_new_run(&"weishidaier", false)
	var player := await _spawn_player()
	var combat_runtime := PLAYER_TEST_RUNTIME.new() as PlayerTestCombatRuntime
	test_root.add_child(combat_runtime)
	player.bind_combat_runtime(combat_runtime)
	_expect(
		run_state.try_add_item_count(VOID_BATTERY, 2),
		"虚空电池事务测试必须建立两件堆叠。"
	)
	var slot_index := _find_local_item_slot(VOID_BATTERY)
	_expect(run_state.try_use_item(slot_index, player), "未充能时必须能使用虚空电池。")
	_expect(
		player.has_void_battery_charge()
		and run_state.get_item_count(slot_index) == 1,
		"首次使用虚空电池必须只扣一件并建立一层充能。"
	)
	var revision_before := run_state.get_inventory_revision()
	_expect(not run_state.try_use_item(slot_index, player), "已充能时必须拒绝第二块虚空电池。")
	_expect(
		run_state.get_inventory_revision() == revision_before
		and run_state.get_item_count(slot_index) == 1,
		"已充能拒绝使用时不得扣物品或推进revision。"
	)
	player.skill1_charge = 0.0
	player.set("_last_skill_activation_msec", -1000000)
	_expect(player._try_use_skill1(), "零技力且已充能时必须能免费施放技能。")
	_expect(
		not player.has_void_battery_charge()
		and is_zero_approx(player.skill1_charge),
		"下一次成功技能必须消耗虚空充能并保留原有零技力。"
	)

	_expect(run_state.try_use_item(slot_index, player), "充能消耗后必须能使用剩余虚空电池。")
	player.skill1_charge = 2.0
	player.set_controls_locked(true)
	player.set("_last_skill_activation_msec", -1000000)
	_expect(not player._try_use_skill1(), "操作锁定时技能必须失败。")
	_expect(player.has_void_battery_charge(), "失败的技能尝试不得消耗虚空充能。")
	player.set_controls_locked(false)
	player.set("_last_skill_activation_msec", -1000000)
	_expect(player._try_use_skill1(), "解除锁定后低技力技能必须成功。")
	_expect(
		not player.has_void_battery_charge()
		and is_equal_approx(player.skill1_charge, 2.0),
		"成功重试必须只消耗充能并保留原有低技力。"
	)
	var replacement_player := await _spawn_player()
	_expect(
		not replacement_player.has_void_battery_charge()
		and is_zero_approx(replacement_player.potion_magic_defense_time_left)
		and is_zero_approx(replacement_player.potion_regeneration_time_left),
		"换场或重连创建的新Player实例不得恢复任何药水或虚空充能。"
	)
	_stop_audio_players(replacement_player)
	replacement_player.queue_free()
	_stop_audio_players(player)
	player.queue_free()
	combat_runtime.queue_free()
	await process_frame
	await physics_frame


func _find_local_item_slot(expected_item: PickupConfig) -> int:
	for slot_index in RunStateStore.INVENTORY_CAPACITY:
		if run_state.get_item(slot_index) == expected_item:
			return slot_index
	return -1


func _spawn_player() -> Player:
	var player := PLAYER_SCENE.instantiate() as Player
	test_root.add_child(player)
	await process_frame
	await physics_frame
	player.set_physics_process(false)
	return player


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
