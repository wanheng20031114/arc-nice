extends SceneTree

const PLAYER_SCENE := preload("res://scene/player.tscn")
const GAME_SCENE := preload("res://scene/game.tscn")
const LUOXI_SCENE := preload("res://scene/luoxi_merchant.tscn")
const BULLET_SCENE := preload("res://scene/bullet.tscn")
const INVENTORY_SLOT_SCENE := preload("res://scene/inventory_slot.tscn")
const BASIC_CONFIG := preload("res://resources/config/enemies/yuanshi_insect_basic.tres")
const APPLE_COLLECTIBLE := preload("res://resources/config/pickups/collectible_apple.tres")

var failures: Array[String] = []
var test_root: Node2D


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	test_root = Node2D.new()
	test_root.name = "LuoxiCollectibleSmokeTest"
	root.add_child(test_root)
	current_scene = test_root

	await _test_luoxi_game_scene_placement()
	await _test_luoxi_dialogue_choice_and_inventory()
	await _test_apple_piercing_bullet_effect()

	test_root.queue_free()
	for _cleanup_frame in range(8):
		await process_frame
		await physics_frame

	if failures.is_empty():
		print("LUOXI_COLLECTIBLE_SMOKE_TEST_OK")
		quit()
		return

	for failure in failures:
		push_error(failure)
	quit(1)


func _test_luoxi_game_scene_placement() -> void:
	var game := GAME_SCENE.instantiate() as Game
	_expect(game != null, "Game scene must instantiate for Luoxi placement.")
	if game == null:
		return
	game.set("auto_start_waves", false)
	root.add_child(game)
	await process_frame
	await physics_frame

	var zhuangfangyi := game.get_node_or_null("ZhuangfangyiMerchant") as ZhuangfangyiMerchant
	var luoxi := game.get_node_or_null("LuoxiMerchant") as LuoxiMerchant
	_expect(zhuangfangyi != null, "Game must keep Zhuangfangyi merchant.")
	_expect(luoxi != null, "Game must instantiate Luoxi merchant.")
	if zhuangfangyi != null and luoxi != null:
		_expect(luoxi.position.x > zhuangfangyi.position.x, "Luoxi must be placed to the right of Zhuangfangyi.")
		var zhuang_shape := zhuangfangyi.get_node("InteractionArea/CollisionShape2D") as CollisionShape2D
		var luoxi_shape := luoxi.get_node("InteractionArea/CollisionShape2D") as CollisionShape2D
		var zhuang_circle := zhuang_shape.shape as CircleShape2D
		var luoxi_circle := luoxi_shape.shape as CircleShape2D
		_expect(
			zhuangfangyi.position.distance_to(luoxi.position) > zhuang_circle.radius + luoxi_circle.radius,
			"Luoxi and Zhuangfangyi interaction circles must not overlap."
		)

	_stop_audio_players(game)
	game.queue_free()
	await process_frame
	await physics_frame


func _test_luoxi_dialogue_choice_and_inventory() -> void:
	var run_state := root.get_node("RunState") as RunStateStore
	run_state.begin_new_run()

	var luoxi := LUOXI_SCENE.instantiate() as LuoxiMerchant
	var player := PLAYER_SCENE.instantiate() as Player
	test_root.add_child(luoxi)
	test_root.add_child(player)
	luoxi.set_active(true)
	await process_frame
	await physics_frame

	luoxi.call("_on_interaction_area_body_entered", player)
	var bubble := luoxi.get_node("MerchantDialogueBubble") as MerchantDialogueBubble
	_expect(bubble.visible, "Luoxi dialogue bubble must appear when the player enters range.")
	_expect(bubble.text_label.text == "我是终末地的爪牙！", "Luoxi dialogue must start at the requested first line.")

	var bubble_panel := bubble.get_node("BubblePanel") as PanelContainer
	var bubble_style := bubble_panel.get_theme_stylebox("panel") as StyleBoxFlat
	_expect(
		bubble_style != null and bubble_style.border_color.r > 0.9 and bubble_style.border_color.g < 0.25,
		"Luoxi dialogue bubble must use a vivid red accent instead of Zhuangfangyi green."
	)

	var interact := _make_action("interact")
	bubble.finish_line()
	luoxi._unhandled_input(interact)
	_expect(
		bubble.text_label.text == "我能为你提供收藏品来强化自己",
		"Luoxi dialogue must include the requested collectible intro line."
	)

	bubble.finish_line()
	luoxi._unhandled_input(interact)
	_expect(bubble.text_label.text.contains("苹果"), "Luoxi choice text must offer apples.")
	_expect(
		bubble.text_label.text.contains(APPLE_COLLECTIBLE.description),
		"Luoxi choice text must show the apple description."
	)

	var move_right := _make_action("move_right")
	bubble.finish_line()
	luoxi._unhandled_input(move_right)
	_expect(int(luoxi.get("selected_choice_index")) == 1, "Luoxi choice selection must move right.")

	luoxi._unhandled_input(interact)
	var item := run_state.get_item(0)
	_expect(item == APPLE_COLLECTIBLE, "Luoxi must add the selected apple to the first inventory slot.")
	_expect(
		item != null and item.description == "玩家持有时发射子弹有50%概率发出可穿透敌人的子弹",
		"Apple collectible must keep the requested description."
	)
	_expect(
		is_equal_approx(player.call("_get_inventory_bullet_pierce_chance"), 0.5),
		"Holding the apple must expose a 50% piercing bullet chance."
	)

	_expect(not run_state.try_use_item(0, player), "Apple collectible must not be consumable from inventory.")
	_expect(run_state.get_item(0) == APPLE_COLLECTIBLE, "Apple collectible must remain in inventory after use attempt.")
	var slot := INVENTORY_SLOT_SCENE.instantiate() as InventorySlot
	test_root.add_child(slot)
	slot.set_item(APPLE_COLLECTIBLE)
	_expect(
		slot.tooltip_text.contains(APPLE_COLLECTIBLE.description),
		"Apple inventory tooltip must show its description."
	)
	slot.queue_free()

	bubble.finish_line()
	luoxi._unhandled_input(interact)
	luoxi._unhandled_input(interact)
	_expect(
		bubble.text_label.text == "这个回合我已经把收藏品交给你了。",
		"Luoxi must not offer another collectible after one choice in the same run."
	)
	_expect(run_state.get_item(1) == null, "Luoxi must not add a second collectible in the same run.")

	luoxi.queue_free()
	player.queue_free()
	await process_frame
	await physics_frame


func _test_apple_piercing_bullet_effect() -> void:
	var player := PLAYER_SCENE.instantiate() as Player
	var enemy_a := BASIC_CONFIG.enemy_scene.instantiate() as Enemy
	var enemy_b := BASIC_CONFIG.enemy_scene.instantiate() as Enemy
	var bullet := BULLET_SCENE.instantiate() as Bullet
	test_root.add_child(player)
	test_root.add_child(enemy_a)
	test_root.add_child(enemy_b)
	enemy_a.setup(BASIC_CONFIG, player, null)
	enemy_b.setup(BASIC_CONFIG, player, null)
	await process_frame
	await physics_frame

	enemy_a.current_health = 10
	enemy_b.current_health = 10
	bullet.setup(Vector2.RIGHT, 3, true)
	test_root.add_child(bullet)
	bullet.global_position = Vector2(-1000.0, -1000.0)

	_expect(bullet.try_hit_enemy(enemy_a), "Piercing bullet must hit the first enemy.")
	_expect(enemy_a.current_health == 7, "Piercing bullet must damage the first enemy.")
	_expect(not bullet.is_queued_for_deletion(), "Piercing bullet must not be removed after the first enemy.")
	_expect(not bullet.try_hit_enemy(enemy_a), "Piercing bullet must not damage the same enemy twice.")
	_expect(enemy_a.current_health == 7, "Repeated piercing hit on the same enemy must not deal damage.")
	_expect(bullet.try_hit_enemy(enemy_b), "Piercing bullet must hit a second enemy.")
	_expect(enemy_b.current_health == 7, "Piercing bullet must damage the second enemy.")

	bullet.queue_free()
	enemy_a.queue_free()
	enemy_b.queue_free()
	player.queue_free()
	await process_frame
	await physics_frame


func _make_action(action_name: StringName) -> InputEventAction:
	var event := InputEventAction.new()
	event.action = action_name
	event.pressed = true
	return event


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
