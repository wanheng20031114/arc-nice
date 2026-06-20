extends SceneTree

const ENEMY_SCENE := preload("res://scene/enemy.tscn")
const ENEMY_CONFIG := preload("res://resources/config/enemies/yuanshi_insect_basic.tres")

var failures: Array[String] = []
var test_root: Node2D


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	test_root = Node2D.new()
	test_root.name = "DamageNumberSmokeTest"
	root.add_child(test_root)
	current_scene = test_root

	var enemy := ENEMY_SCENE.instantiate() as Enemy
	_expect(enemy != null, "Enemy scene must instantiate.")
	test_root.add_child(enemy)
	enemy.global_position = Vector2(64.0, 64.0)
	enemy.setup(ENEMY_CONFIG, null, null)

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
	_expect(label.get_theme_font_size(&"font_size") >= 18, "DamageNumber font should be large enough to read.")
	_expect(label.get_theme_constant(&"outline_size") >= 5, "DamageNumber outline should be thick.")
	var font_color := label.get_theme_color(&"font_color")
	_expect(font_color.r > 0.9 and font_color.g < 0.25 and font_color.b < 0.2, "DamageNumber should be red.")
	var outline_color := label.get_theme_color(&"font_outline_color")
	_expect(outline_color.r > outline_color.g and outline_color.r > outline_color.b, "DamageNumber outline should be dark red.")
