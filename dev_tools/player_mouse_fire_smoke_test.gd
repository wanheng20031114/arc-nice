extends SceneTree

const GAME_SCENE := preload("res://scene/game.tscn")

var failures: Array[String] = []
var game: Node2D
var player: Player


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	game = GAME_SCENE.instantiate() as Node2D
	game.set("initial_spawn_count", 0)
	game.set("spawn_interval", 60.0)
	game.set("current_music_stage", 0)
	var test_music_player := game.get_node("MusicPlayer") as AudioStreamPlayer
	test_music_player.autoplay = false
	root.add_child(game)
	current_scene = game
	await process_frame
	await physics_frame

	player = game.get_node("Player") as Player
	await _test_world_mouse_fire()
	await _test_profile_button_does_not_fire()

	_release_left_mouse(Vector2.ZERO)
	game.queue_free()
	await process_frame
	await physics_frame
	await process_frame

	if failures.is_empty():
		print("PLAYER_MOUSE_FIRE_SMOKE_TEST_OK")
		quit()
		return

	for failure in failures:
		push_error(failure)
	quit(1)


func _test_world_mouse_fire() -> void:
	var target_viewport_position := (
		player.get_global_transform_with_canvas() * Vector2(80.0, 0.0)
	)
	_press_left_mouse(target_viewport_position)
	await process_frame
	await process_frame
	await _wait_physics_frames(2)

	_expect(player.mouse_fire_held, "World left click did not start mouse firing.")
	var first_bullet := _find_player_bullet()
	_expect(
		first_bullet != null,
		"World left click did not spawn a bullet. Mouse viewport position: %s, player: %s."
		% [player.mouse_viewport_position, player.global_position]
	)
	if first_bullet != null:
		_expect(
			first_bullet.direction.dot(Vector2.RIGHT) > 0.99,
			"Mouse-fired bullet did not travel toward the cursor. Direction: %s, mouse world: %s, target viewport: %s."
			% [
				first_bullet.direction,
				player.get_canvas_transform().affine_inverse()
				* player.mouse_viewport_position,
				target_viewport_position,
			]
		)
	_expect(
		player.facing_suffix == &"right",
		"Player did not face the mouse firing direction. Facing: %s." % player.facing_suffix
	)

	var initial_bullet_count := _get_player_bullet_count()
	await _wait_physics_frames(16)
	_expect(
		_get_player_bullet_count() > initial_bullet_count,
		"Holding left click did not continue firing."
	)

	_release_left_mouse(target_viewport_position)
	await process_frame
	await process_frame
	await physics_frame
	_expect(not player.mouse_fire_held, "Releasing left click did not stop mouse firing.")

	player.mouse_fire_held = true
	player.call("_on_window_focus_exited")
	_expect(not player.mouse_fire_held, "Losing window focus did not stop mouse firing.")


func _test_profile_button_does_not_fire() -> void:
	for child in game.get_children():
		if child is Bullet:
			child.queue_free()
	await process_frame

	var profile_button := game.get_node(
		"CurrencyHUD/TopRightMargin/Content/ProfileButton"
	) as Button
	var profile_panel := game.get_node("PlayerProfilePanel") as PlayerProfilePanel
	var button_position := profile_button.get_global_rect().get_center()

	_press_left_mouse(button_position)
	await process_frame
	await process_frame
	await physics_frame
	var hovered_control := root.gui_get_hovered_control()
	_expect(
		not player.mouse_fire_held,
		"Clicking the profile button leaked into player firing. Button rect: %s, click: %s, hovered: %s."
		% [profile_button.get_global_rect(), button_position, hovered_control]
	)
	_expect(
		_get_player_bullet_count() == 0,
		"Clicking the profile button spawned a player bullet."
	)

	_release_left_mouse(button_position)
	await process_frame
	await process_frame
	await physics_frame
	_expect(
		profile_panel.is_open(),
		"Profile button did not open the profile panel. Viewport size: %s."
		% root.get_visible_rect().size
	)
	_expect(player.controls_locked, "Opening the profile panel did not lock player controls.")
	_expect(not player.mouse_fire_held, "Opening the profile panel left mouse firing active.")


func _press_left_mouse(position: Vector2) -> void:
	_send_mouse_motion(position)
	var event := InputEventMouseButton.new()
	event.position = position
	event.global_position = position
	event.button_index = MOUSE_BUTTON_LEFT
	event.button_mask = MOUSE_BUTTON_MASK_LEFT
	event.pressed = true
	root.push_input(event, true)


func _release_left_mouse(position: Vector2) -> void:
	var event := InputEventMouseButton.new()
	event.position = position
	event.global_position = position
	event.button_index = MOUSE_BUTTON_LEFT
	event.button_mask = 0
	event.pressed = false
	root.push_input(event, true)


func _send_mouse_motion(position: Vector2) -> void:
	var event := InputEventMouseMotion.new()
	event.position = position
	event.global_position = position
	root.push_input(event, true)


func _find_player_bullet() -> Bullet:
	for child in game.get_children():
		var bullet := child as Bullet
		if bullet != null:
			return bullet
	return null


func _get_player_bullet_count() -> int:
	var bullet_count := 0
	for child in game.get_children():
		if child is Bullet:
			bullet_count += 1
	return bullet_count


func _wait_physics_frames(frame_count: int) -> void:
	for _frame_index in range(frame_count):
		await physics_frame


func _expect(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)
