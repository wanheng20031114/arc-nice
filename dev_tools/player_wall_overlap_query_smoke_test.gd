extends SceneTree

const PLAYER_SCENE := preload("res://scene/player/tiyi/player_tiyi.tscn")

var failures: Array[String] = []


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	var fixture := Node2D.new()
	fixture.name = "PlayerWallOverlapQuerySmokeTest"
	root.add_child(fixture)
	current_scene = fixture
	var player := PLAYER_SCENE.instantiate() as Player
	fixture.add_child(player)
	player.uses_local_input = false
	player.network_move_input = Vector2.ZERO
	await process_frame
	await physics_frame
	player.set_physics_process(false)

	var query_instance_id := player._wall_overlap_query.get_instance_id()
	player.global_position = Vector2(320.0, 128.0)
	player._wall_overlap_expected_position = player.global_position
	player._wall_overlap_probe_required = false
	var sentinel_transform := Transform2D(0.0, Vector2(9000.0, 9000.0))
	player._wall_overlap_query.transform = sentinel_transform
	player.network_move_input = Vector2.RIGHT
	player.set_physics_process(true)
	await physics_frame
	player.set_physics_process(false)
	_expect(
		player.global_position.x > 320.0,
		"Open-ground gated movement must preserve the authored player speed."
	)
	_expect(
		player._wall_overlap_query.transform == sentinel_transform,
		"Confirmed open-ground movement must skip the wall-overlap physics query."
	)
	_expect(
		player._wall_overlap_query.get_instance_id() == query_instance_id,
		"Wall-overlap checks must retain one reusable query object."
	)

	player._wall_overlap_probe_required = false
	player.global_position += Vector2(80.0, 0.0)
	player.call("_refresh_wall_overlap_probe_gate")
	_expect(
		player._wall_overlap_probe_required,
		"An external position correction must re-arm overlap probing immediately."
	)

	var wall := StaticBody2D.new()
	wall.collision_layer = 1
	wall.collision_mask = 0
	var wall_shape_node := CollisionShape2D.new()
	var wall_shape := RectangleShape2D.new()
	wall_shape.size = Vector2(32.0, 64.0)
	wall_shape_node.shape = wall_shape
	wall.add_child(wall_shape_node)
	fixture.add_child(wall)
	wall.global_position = Vector2.ZERO
	player.global_position = Vector2(20.0, 0.0)
	await physics_frame
	var overlap_before := int(player.call(
		"_count_world_shape_overlaps",
		player.collision_shape.global_transform
	))
	var escape_start := player.global_position
	var escaped := bool(player.call(
		"_try_apply_wall_overlap_escape",
		Vector2.RIGHT,
		1.0 / float(maxi(Engine.physics_ticks_per_second, 1))
	))
	var overlap_after := int(player.call(
		"_count_world_shape_overlaps",
		player.collision_shape.global_transform
	))
	_expect(overlap_before > 0, "Wall fixture must begin with a real body overlap.")
	_expect(
		escaped
		and player.global_position.x > escape_start.x
		and overlap_after <= overlap_before,
		"Outward wall escape must retain its exact non-increasing-overlap movement contract."
	)

	player.global_position = Vector2(20.0, 0.0)
	await physics_frame
	var inward_start := player.global_position
	var escaped_inward := bool(player.call(
		"_try_apply_wall_overlap_escape",
		Vector2.LEFT,
		1.0 / float(maxi(Engine.physics_ticks_per_second, 1))
	))
	_expect(
		not escaped_inward and player.global_position == inward_start,
		"Inward input must never use direct overlap-escape translation."
	)

	player.global_position = Vector2(30.0, 0.0)
	player._wall_overlap_expected_position = player.global_position
	player._wall_overlap_probe_required = false
	player.network_move_input = Vector2.LEFT
	player.set_physics_process(true)
	for _frame in range(16):
		await physics_frame
	player.set_physics_process(false)
	_expect(
		player._wall_overlap_probe_required,
		"A regular CharacterBody wall collision must re-arm overlap probing."
	)

	player.queue_free()
	wall.queue_free()
	await process_frame
	await physics_frame
	if failures.is_empty():
		print("PLAYER_WALL_OVERLAP_QUERY_SMOKE_TEST_OK")
		quit(0)
		return
	for failure in failures:
		push_error(failure)
	quit(1)


func _expect(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)
