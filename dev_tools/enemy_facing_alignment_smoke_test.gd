extends SceneTree

var failures: Array[String] = []


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	var test_root := Node2D.new()
	test_root.name = "EnemyFacingAlignmentSmokeTest"
	root.add_child(test_root)

	var tested_enemy_scene_count := 0
	var tested_nested_enemy_scene_count := 0
	for scene_path in _enemy_scene_paths():
		var scene := load(scene_path) as PackedScene
		if scene == null:
			continue
		var instance := scene.instantiate()
		var enemy := instance as Enemy
		if enemy == null:
			instance.free()
			continue
		tested_enemy_scene_count += 1
		if scene_path.trim_prefix("res://scene/enemy/").contains("/"):
			tested_nested_enemy_scene_count += 1
		test_root.add_child(enemy)
		await process_frame
		_test_enemy_facing_alignment(enemy, scene_path)
		enemy.queue_free()
		await process_frame
	if tested_enemy_scene_count <= 0:
		failures.append(
			"Facing-alignment discovery must cover at least one Enemy scene."
		)
	if tested_nested_enemy_scene_count <= 0:
		failures.append(
			"Facing-alignment discovery must recurse into enemy category directories."
		)

	test_root.queue_free()
	await process_frame

	if failures.is_empty():
		print("ENEMY_FACING_ALIGNMENT_SMOKE_TEST_OK")
		quit()
		return

	for failure in failures:
		push_error(failure)
	quit(1)


func _enemy_scene_paths() -> Array[String]:
	var paths: Array[String] = []
	_append_enemy_scene_paths_recursive("res://scene/enemy", paths)
	paths.sort()
	return paths


func _append_enemy_scene_paths_recursive(
	directory_path: String,
	paths: Array[String]
) -> void:
	for file_name in DirAccess.get_files_at(directory_path):
		if file_name.ends_with(".tscn"):
			paths.append("%s/%s" % [directory_path, file_name])
	for directory_name in DirAccess.get_directories_at(directory_path):
		_append_enemy_scene_paths_recursive(
			"%s/%s" % [directory_path, directory_name],
			paths
		)


func _test_enemy_facing_alignment(enemy: Enemy, scene_path: String) -> void:
	var animated_sprite := enemy.get_node_or_null("AnimatedSprite2D") as AnimatedSprite2D
	if animated_sprite == null:
		failures.append("%s has no AnimatedSprite2D." % scene_path)
		return

	enemy.call("_set_facing_left", false)
	var right_sprite_position := animated_sprite.position
	var right_shape_positions := _shape_positions(enemy)
	var expected_right_flip := false != enemy.sprite_faces_left_by_default
	if animated_sprite.flip_h != expected_right_flip:
		failures.append("%s right-facing flip_h mismatch." % scene_path)

	enemy.call("_set_facing_left", true)
	var left_sprite_position := animated_sprite.position
	var expected_left_flip := true != enemy.sprite_faces_left_by_default
	if animated_sprite.flip_h != expected_left_flip:
		failures.append("%s left-facing flip_h mismatch." % scene_path)
	if not is_equal_approx(left_sprite_position.x, -right_sprite_position.x):
		failures.append(
			"%s AnimatedSprite2D.position.x did not mirror around the scene x=0 axis: right=%s left=%s"
			% [scene_path, str(right_sprite_position), str(left_sprite_position)]
		)
	if not is_equal_approx(left_sprite_position.y, right_sprite_position.y):
		failures.append(
			"%s AnimatedSprite2D.position.y changed while facing: right=%s left=%s"
			% [scene_path, str(right_sprite_position), str(left_sprite_position)]
		)

	var left_shape_positions := _shape_positions(enemy)
	for node_path in right_shape_positions:
		if not left_shape_positions.has(node_path):
			failures.append("%s missing mirrored collision shape %s." % [scene_path, node_path])
			continue
		var right_position := right_shape_positions[node_path] as Vector2
		var left_position := left_shape_positions[node_path] as Vector2
		if not is_equal_approx(left_position.x, -right_position.x) or not is_equal_approx(left_position.y, right_position.y):
			failures.append(
				"%s collision shape %s did not mirror: right=%s left=%s"
				% [scene_path, node_path, str(right_position), str(left_position)]
			)

	enemy.call("_set_facing_left", false)
	if not animated_sprite.position.is_equal_approx(right_sprite_position):
		failures.append(
			"%s AnimatedSprite2D.position did not restore after facing reset: expected=%s actual=%s"
			% [scene_path, str(right_sprite_position), str(animated_sprite.position)]
		)


func _shape_positions(enemy: Enemy) -> Dictionary:
	var positions := {}
	var shapes: Array[CollisionShape2D] = []
	shapes.append_array(enemy.body_collision_shapes)
	shapes.append_array(enemy.touch_damage_shapes)
	for shape_node in shapes:
		if shape_node == null:
			continue
		positions[str(shape_node.get_path())] = shape_node.position
	return positions
