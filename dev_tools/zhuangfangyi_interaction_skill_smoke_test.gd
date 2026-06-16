extends SceneTree

const PLAYER_SCENE := preload("res://scene/player.tscn")
const MERCHANT_SCENE := preload("res://scene/zhuangfangyi_merchant.tscn")
const ENEMY_SCENE := preload("res://scene/yuanshi_insect.tscn")
const BASIC_CONFIG := preload("res://resources/config/enemies/yuanshi_insect_basic.tres")

var failures: Array[String] = []
var test_root: Node2D


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	test_root = Node2D.new()
	test_root.name = "ZhuangfangyiInteractionSkillSmokeTest"
	root.add_child(test_root)
	current_scene = test_root

	await _test_merchant_collision_is_solid_on_spawn()
	await _test_dialogue_purchase()
	await _test_skill_charge_and_bomb_direction()
	await _test_bomb_explosion_damage()

	test_root.queue_free()
	for _cleanup_frame in range(8):
		await process_frame
		await physics_frame

	if failures.is_empty():
		print("ZHUANGFANGYI_INTERACTION_SKILL_SMOKE_TEST_OK")
		quit()
		return

	for failure in failures:
		push_error(failure)
	quit(1)


func _test_merchant_collision_is_solid_on_spawn() -> void:
	var merchant := MERCHANT_SCENE.instantiate() as ZhuangfangyiMerchant
	var player := PLAYER_SCENE.instantiate() as Player
	test_root.add_child(merchant)
	test_root.add_child(player)
	merchant.global_position = Vector2.ZERO
	player.global_position = Vector2.ZERO
	await process_frame
	await physics_frame

	merchant.set_active(true)
	await process_frame
	await physics_frame
	await process_frame
	_expect(merchant.visible, "Merchant must stay visible when active.")
	_expect(
		not (merchant.get_node("StaticBody2D/CollisionShape2D") as CollisionShape2D).disabled,
		"Merchant collision must be solid even when spawned on top of a player."
	)
	_expect(
		player.global_position.distance_to(merchant.global_position) > 18.0,
		"Player must be pushed out when the merchant spawns on top of them."
	)

	merchant.queue_free()
	player.queue_free()
	await process_frame
	await physics_frame


func _test_dialogue_purchase() -> void:
	var merchant := MERCHANT_SCENE.instantiate() as ZhuangfangyiMerchant
	var player := PLAYER_SCENE.instantiate() as Player
	test_root.add_child(merchant)
	test_root.add_child(player)
	player.current_xirang = 250
	merchant.set_active(true)
	await process_frame
	await physics_frame

	merchant.call("_on_interaction_area_body_entered", player)
	var bubble := merchant.get_node("MerchantDialogueBubble") as MerchantDialogueBubble
	_expect(bubble.visible, "Dialogue bubble must appear when the player enters interaction range.")
	_expect(bubble.text_label.text == "你好，我是终末地的庄方宜", "Dialogue did not start at the first line.")

	var event := InputEventAction.new()
	event.action = "interact"
	event.pressed = true
	for _index in range(3):
		bubble.finish_line()
		merchant._unhandled_input(event)
	_expect(bubble.text_label.text.contains("[img=22]"), "Purchase dialogue must show the skill icon inline.")

	bubble.finish_line()
	merchant._unhandled_input(event)

	_expect(player.has_skill1(), "Purchasing the dialogue skill must unlock player skill1.")
	_expect(player.current_xirang == 50, "Purchasing skill1 must cost exactly 200 xirang.")
	_expect(player.get_node("Skill1ChargeBar").visible, "Skill1 charge bar must appear after purchase.")
	_expect(not player.get_node("Skill1ChargeBar").has_node("Icon"), "Skill1 charge bar must not include the dialogue skill icon.")

	var current_xirang := player.current_xirang
	bubble.finish_line()
	merchant._unhandled_input(event)
	_expect(player.current_xirang == current_xirang, "Skill1 purchase must not repeat after it is already owned.")

	merchant.queue_free()
	player.queue_free()
	await process_frame
	await physics_frame


func _test_skill_charge_and_bomb_direction() -> void:
	var player := PLAYER_SCENE.instantiate() as Player
	test_root.add_child(player)
	await process_frame
	await physics_frame

	_expect(not player.call("_try_use_skill1"), "Skill1 must not fire before it is unlocked.")
	player.unlock_skill1()
	player.call("_update_skill1_charge", 18.0)
	player.last_attack_direction = Vector2.UP
	_expect(player.call("_try_use_skill1"), "Skill1 must fire after charging to 18 seconds.")
	_expect(is_equal_approx(player.skill1_charge, 0.0), "Skill1 charge must reset after firing.")

	var bomb: WeishidaierSkill1Bomb = null
	for child in test_root.get_children():
		bomb = child as WeishidaierSkill1Bomb
		if bomb != null:
			break
	_expect(bomb != null, "Skill1 did not spawn a bomb.")
	if bomb != null:
		_expect(bomb.direction.dot(Vector2.UP) > 0.99, "Skill1 bomb did not use the last attack direction.")
		bomb.queue_free()

	player.queue_free()
	await process_frame
	await physics_frame


func _test_bomb_explosion_damage() -> void:
	var player := PLAYER_SCENE.instantiate() as Player
	var other_player := PLAYER_SCENE.instantiate() as Player
	var enemy := ENEMY_SCENE.instantiate() as YuanshiInsect
	var bomb := preload("res://scene/weishidaier_skill1_bomb.tscn").instantiate() as WeishidaierSkill1Bomb
	var explosion_shape := bomb.get_node("ExplosionShape") as CollisionShape2D
	var explosion_circle := explosion_shape.shape as CircleShape2D
	_expect(bomb.has_node("AnimatedSprite2D"), "Skill1 bomb must use an animated projectile sprite.")
	_expect(not bomb.has_node("Sprite2D"), "Skill1 bomb must not reuse the square skill icon sprite.")
	_expect(
		explosion_circle != null and is_equal_approx(explosion_circle.radius, 44.0),
		"Skill1 explosion visual and damage radius must be 44 pixels."
	)
	test_root.add_child(player)
	test_root.add_child(other_player)
	test_root.add_child(enemy)
	player.global_position = Vector2.ZERO
	other_player.global_position = Vector2(5, 0)
	enemy.global_position = Vector2(8, 0)
	enemy.setup(BASIC_CONFIG, player, null)
	await process_frame
	await physics_frame

	player.attack_damage = 4
	enemy.current_health = 20
	var other_health := other_player.current_health
	bomb.setup(player, Vector2.RIGHT, floori(float(player.attack_damage) * 3.3))
	test_root.add_child(bomb)
	bomb.global_position = Vector2.ZERO
	await process_frame
	bomb.call("_explode")
	await process_frame
	_expect(enemy.current_health == 7, "Skill1 explosion must deal floor(attack * 3.3) damage to enemies.")
	_expect(other_player.current_health == other_health, "Skill1 explosion must not damage players for now.")

	for child in test_root.get_children():
		var explosion := child as WeishidaierSkill1Explosion
		if explosion != null:
			explosion.queue_free()

	player.queue_free()
	other_player.queue_free()
	enemy.queue_free()
	await process_frame
	await physics_frame


func _expect(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)
