extends SceneTree

const ENEMY_SCENE := preload("res://scene/enemy/enemy.tscn")
const ENEMY_CONFIG := preload("res://resources/config/enemies/yuanshi_insect_basic.tres")
const DAMAGE_NUMBER_POOL_SCRIPT := preload("res://scene/damage_number_pool.gd")


class DamageNumberOwner:
	extends Node2D

	var damage_number_pool: Node = null

	func show_damage_number(
		amount: int,
		spawn_position: Vector2,
		impact_direction: Vector2 = Vector2.ZERO
	) -> bool:
		if damage_number_pool == null:
			return false
		return damage_number_pool.call("show_damage_number", amount, spawn_position, impact_direction) == true

var failures: Array[String] = []
var test_root: Node2D


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	var owner := DamageNumberOwner.new()
	test_root = owner
	test_root.name = "DamageNumberSmokeTest"
	root.add_child(test_root)
	current_scene = test_root

	var damage_number_pool := DAMAGE_NUMBER_POOL_SCRIPT.new() as Node2D
	_expect(damage_number_pool != null, "DamageNumberPool should instantiate.")
	if damage_number_pool != null:
		damage_number_pool.name = "DamageNumberPool"
		test_root.add_child(damage_number_pool)
		owner.damage_number_pool = damage_number_pool
	await process_frame

	if damage_number_pool != null:
		_expect(
			damage_number_pool.get_child_count() == int(damage_number_pool.get("pool_size")),
			"DamageNumberPool should prewarm the configured number of nodes."
		)

	var enemy := ENEMY_SCENE.instantiate() as Enemy
	_expect(enemy != null, "Enemy scene must instantiate.")
	test_root.add_child(enemy)
	enemy.global_position = Vector2(64.0, 64.0)
	enemy.setup(ENEMY_CONFIG, null, null)
	var enemy_hit_audio := enemy.get_node("HitAudio") as AudioStreamPlayer2D
	if enemy_hit_audio != null:
		enemy_hit_audio.stream = null

	var before_count := get_nodes_in_group(&"damage_numbers").size()
	var damaged := enemy.apply_damage(10, Vector2.RIGHT)
	_expect(damaged, "Enemy damage should apply.")
	_expect(enemy.last_damage_taken > 0, "Enemy must record confirmed final damage.")
	await process_frame
	var after_count := get_nodes_in_group(&"damage_numbers").size()
	_expect(after_count == before_count + 1, "DamageNumber should be spawned after confirmed damage.")
	var damage_number := _find_damage_number()
	_expect(damage_number != null, "Spawned DamageNumber should be reachable.")
	if damage_number != null:
		_test_damage_number_style(damage_number)
	if damage_number_pool != null:
		await physics_frame
		_test_damage_number_pool_budget(damage_number_pool)

	_stop_audio_players(test_root)
	current_scene = null
	test_root.queue_free()
	await process_frame
	await physics_frame
	for _cleanup_frame in range(4):
		await process_frame
	if failures.is_empty():
		print("DAMAGE_NUMBER_SMOKE_TEST_OK")
		quit()
		return
	for failure in failures:
		push_error(failure)
	quit(1)


func _expect(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)


func _find_damage_number() -> DamageNumber:
	for node in get_nodes_in_group(&"damage_numbers"):
		var damage_number := node as DamageNumber
		if damage_number != null:
			return damage_number
	return null


func _test_damage_number_style(damage_number: DamageNumber) -> void:
	var label := damage_number.label
	_expect(label != null, "DamageNumber should own a Label.")
	if label == null:
		return
	var font := label.get_theme_font(&"font")
	_expect(font != null, "DamageNumber font override should be set.")
	if font != null:
		_expect(
			font.resource_path == "res://resources/font/ResourceHanRoundedCN-Medium.ttf",
			"DamageNumber should use the rounded font instead of the pixel font."
		)
	_expect(label.get_theme_font_size(&"font_size") == 9, "DamageNumber font should be half the previous size.")
	_expect(label.get_theme_constant(&"outline_size") == 2, "DamageNumber outline should stay readable without oversized pixel bulk.")
	_expect(label.size.y >= 20.0, "DamageNumber label box must leave vertical room for the outlined font.")
	_expect(label.size.x >= 38.0, "DamageNumber label box must leave horizontal room for the outlined font.")
	_expect(label.texture_filter == CanvasItem.TEXTURE_FILTER_LINEAR, "DamageNumber should use linear texture filtering.")
	var font_color := label.get_theme_color(&"font_color")
	_expect(font_color.r > 0.9 and font_color.g < 0.25 and font_color.b < 0.2, "DamageNumber should be red.")
	var outline_color := label.get_theme_color(&"font_outline_color")
	_expect(outline_color.r > outline_color.g and outline_color.r > outline_color.b, "DamageNumber outline should be dark red.")


func _test_damage_number_pool_budget(damage_number_pool: Node2D) -> void:
	var child_count_before := damage_number_pool.get_child_count()
	var max_per_frame := int(damage_number_pool.get("max_numbers_per_frame"))
	var shown_count := 0
	for index in range(max_per_frame + 1):
		if damage_number_pool.call(
			"show_damage_number",
			1 + index,
			Vector2(80.0 + float(index), 80.0),
			Vector2.RIGHT
		) == true:
			shown_count += 1
	_expect(shown_count == max_per_frame, "DamageNumberPool should enforce the per-frame display budget.")
	_expect(damage_number_pool.get_child_count() == child_count_before, "DamageNumberPool should reuse prewarmed nodes.")


func _stop_audio_players(node: Node) -> void:
	if node == null:
		return
	if node is AudioStreamPlayer:
		var audio_player := node as AudioStreamPlayer
		audio_player.stop()
		audio_player.stream = null
	elif node is AudioStreamPlayer2D:
		var audio_player_2d := node as AudioStreamPlayer2D
		audio_player_2d.stop()
		audio_player_2d.stream = null
	elif node is AudioStreamPlayer3D:
		var audio_player_3d := node as AudioStreamPlayer3D
		audio_player_3d.stop()
		audio_player_3d.stream = null
	for child in node.get_children():
		_stop_audio_players(child)
