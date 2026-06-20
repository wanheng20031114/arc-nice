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

	test_root.queue_free()
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