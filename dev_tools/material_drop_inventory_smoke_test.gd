extends SceneTree

const PLAYER_SCENE := preload("res://scene/player/weishidaier/player_weishidaier.tscn")
const PROFILE_PANEL_SCENE := preload("res://scene/player/ui/player_profile_panel.tscn")
const BASIC_ENEMY_CONFIG := preload("res://resources/config/enemies/yuanshi_insect_basic.tres")
const TEMPURA := preload("res://resources/config/pickups/pickup_tenpura.tres")
const WOOD := preload("res://resources/config/materials/material_wood.tres")
const SAPLING := preload("res://resources/config/materials/material_sapling.tres")

var failures: Array[String] = []
var test_root: Node2D
var run_state: RunStateStore


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	test_root = Node2D.new()
	test_root.name = "MaterialDropInventorySmokeTest"
	root.add_child(test_root)
	current_scene = test_root
	run_state = root.get_node("RunState") as RunStateStore

	await _test_tempura_attack_buff()
	_test_material_config_and_weighting()
	_test_local_and_peer_stack_limits()
	await _test_material_drop_spawn()
	await _test_material_inventory_detail()

	test_root.queue_free()
	for _cleanup_frame in range(12):
		await process_frame
		await physics_frame

	if failures.is_empty():
		print("MATERIAL_DROP_INVENTORY_SMOKE_TEST_OK")
		quit()
		return
	for failure in failures:
		push_error(failure)
	quit(1)


func _test_tempura_attack_buff() -> void:
	run_state.begin_new_run()
	var player := PLAYER_SCENE.instantiate() as Player
	test_root.add_child(player)
	await process_frame
	await physics_frame
	var base_attack := player.attack_damage
	var base_move_multiplier := player.current_move_speed_multiplier
	_expect(player.apply_pickup(TEMPURA), "Tempura must apply an immediate temporary buff.")
	_expect(player.attack_damage == ceili(float(base_attack) * 1.1), "Tempura must raise attack by 10%, rounded up to the integer stat.")
	_expect(is_equal_approx(player.current_move_speed_multiplier, base_move_multiplier), "Tempura must not change movement speed.")
	player.call("_update_pickup_effects", 2.0)
	_expect(is_equal_approx(player.attack_buff_time_left, 3.0), "Tempura duration must count down from five seconds.")
	_expect(player.apply_pickup(TEMPURA), "A second Tempura must refresh the existing buff.")
	_expect(player.attack_damage == ceili(float(base_attack) * 1.1), "Multiple Tempura buffs must not multiply or add together.")
	_expect(is_equal_approx(player.attack_buff_time_left, 5.0), "A second Tempura must refresh, not extend, the duration.")
	player.call("_update_pickup_effects", 5.1)
	_expect(player.attack_damage == base_attack, "Tempura attack must return to its base value after expiry.")
	_stop_audio_players(player)
	player.queue_free()
	await process_frame
	await physics_frame


func _test_material_config_and_weighting() -> void:
	for material in [WOOD, SAPLING]:
		_expect(material.pickup_type == PickupConfig.PickupType.MATERIAL, "%s must use the material pickup category." % material.display_name)
		_expect(material.can_store_in_inventory and material.stackable, "%s must be a stackable inventory item." % material.display_name)
		_expect(material.inventory_stack_limit == 999, "%s must cap each slot at 999." % material.display_name)
	_expect(is_equal_approx(Enemy.MATERIAL_DROP_CHANCE, 0.03), "Every enemy must have an independent 3% material drop chance.")
	_expect(is_equal_approx(WOOD.drop_weight, 80.0) and is_equal_approx(SAPLING.drop_weight, 20.0), "Material weights must be 80 wood to 20 sapling.")
	var selector := Enemy.new()
	_expect(selector.call("_pick_material_drop_config", 0.0) == WOOD, "The start of the material weight range must select wood.")
	_expect(selector.call("_pick_material_drop_config", 79.999) == WOOD, "Wood must occupy 80% of the material weight range.")
	_expect(selector.call("_pick_material_drop_config", 80.0) == SAPLING, "Sapling must begin at the final 20% of the material weight range.")
	_expect(selector.call("_pick_material_drop_config", 99.999) == SAPLING, "Sapling must occupy the remainder of the material weight range.")
	selector.free()


func _test_local_and_peer_stack_limits() -> void:
	run_state.begin_new_run()
	for _index in range(999):
		_expect(run_state.try_add_item(WOOD), "Wood copy must fit before the first stack reaches 999.")
	_expect(run_state.get_item(0) == WOOD and run_state.get_item_count(0) == 999, "The first wood slot must hold exactly 999 items.")
	_expect(run_state.try_add_item(WOOD), "Wood copy 1000 must spill into another free slot.")
	_expect(run_state.get_item(1) == WOOD and run_state.get_item_count(1) == 1, "A full wood stack must spill into a new slot.")
	for _index in range(20):
		_expect(run_state.try_add_item(SAPLING), "Saplings must stack in their own slot.")
	_expect(run_state.get_item(2) == SAPLING and run_state.get_item_count(2) == 20, "Saplings must not merge with wood.")
	_expect(not run_state.try_use_item(2, null), "Materials must not be consumable.")
	_expect(run_state.discard_item(0), "Deleting a material stack must succeed.")
	_expect(run_state.get_item(0) == null and run_state.get_item_count(0) == 0, "Deleting a material stack must clear the whole selected slot.")

	run_state.ensure_multiplayer_peer_state(7)
	for _index in range(999):
		_expect(run_state.try_add_item_for_peer(7, SAPLING), "Peer sapling copy must fit before 999.")
	_expect(run_state.get_item_count_for_peer(7, 0) == 999, "Peer material stacks must use the same 999 limit.")
	_expect(run_state.try_add_item_for_peer(7, SAPLING), "Peer material copy 1000 must spill into another slot.")
	_expect(run_state.get_item_count_for_peer(7, 1) == 1, "Peer material overflow must use a second slot.")


func _test_material_drop_spawn() -> void:
	var player := PLAYER_SCENE.instantiate() as Player
	var enemy := BASIC_ENEMY_CONFIG.enemy_scene.instantiate() as Enemy
	test_root.add_child(player)
	test_root.add_child(enemy)
	enemy.setup(BASIC_ENEMY_CONFIG, player, null)
	await process_frame
	enemy.call("_spawn_material_drop", WOOD, Vector2(12.0, 18.0))
	await process_frame
	var spawned_material: Pickup = null
	for child in test_root.get_children():
		var pickup := child as Pickup
		if pickup != null and pickup.config == WOOD:
			spawned_material = pickup
			break
	_expect(spawned_material != null, "The base Enemy material path must create a normal pickup for every enemy subclass.")
	if spawned_material != null:
		_expect(spawned_material.global_position == Vector2(12.0, 18.0), "Material pickup must spawn at the defeated enemy position.")
		spawned_material.queue_free()
	enemy.queue_free()
	player.queue_free()
	await process_frame
	await physics_frame


func _test_material_inventory_detail() -> void:
	run_state.begin_new_run()
	_expect(run_state.try_add_item(WOOD) and run_state.try_add_item(WOOD), "UI setup must create a two-item wood stack.")
	var player := PLAYER_SCENE.instantiate() as Player
	var profile := PROFILE_PANEL_SCENE.instantiate() as PlayerProfilePanel
	test_root.add_child(player)
	test_root.add_child(profile)
	await process_frame
	await physics_frame
	profile.bind_player(player)
	profile.open()
	await process_frame
	profile.slots[0].emit_signal("pressed")
	await process_frame
	_expect(profile.slots[0].stack_count_label.visible and profile.slots[0].stack_count_label.text == "2", "A material slot must display its stack count.")
	_expect(profile.item_detail_title.text == "木头 ×2", "Material detail must include the selected stack count.")
	_expect(profile.item_detail_category_label.text == "物资", "Material detail must show the new material category.")
	_expect(profile.item_detail_description.text.contains(WOOD.description), "Material detail must show its description.")
	_expect(not profile.item_detail_use_button.visible, "Materials must not show a use button.")
	_expect(not profile.item_detail_hint.visible, "Materials must not show a double-click use hint.")
	_expect(profile.item_detail_discard_button.visible and profile.item_detail_discard_button.text == "删除", "Materials must show only a delete action.")
	var double_click := InputEventMouseButton.new()
	double_click.button_index = MOUSE_BUTTON_LEFT
	double_click.pressed = true
	double_click.double_click = true
	profile.slots[0]._on_gui_input(double_click)
	await process_frame
	_expect(run_state.get_item_count(0) == 2, "Double-clicking a material must not consume it.")
	profile.item_detail_discard_button.emit_signal("pressed")
	await process_frame
	_expect(run_state.get_item(0) == null, "The material delete button must remove the whole selected stack.")
	profile.close()
	profile.queue_free()
	player.queue_free()
	await process_frame
	await physics_frame


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
