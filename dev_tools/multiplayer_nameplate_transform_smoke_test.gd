extends SceneTree

const PLAYER_SCENES: Array[PackedScene] = [
	preload("res://scene/player/weishidaier/player_weishidaier.tscn"),
	preload("res://scene/player/tiyi/player_tiyi.tscn"),
	preload("res://scene/player/tango/player_tango.tscn"),
	preload("res://scene/player/hoe_cat/player_hoe_cat.tscn"),
]
const VIEWPORT_SIZE := Vector2i(1152, 648)
const CAMERA_ZOOM := Vector2(2.0, 2.0)
const EXPECTED_NAMEPLATE_ANCHOR := Vector2(0.0, -19.0)
const EXPECTED_CONTENT_SCALE := Vector2(0.5, 0.5)
const EXPECTED_SCREEN_SIZE := Vector2(160.0, 30.0)
const FACING_DIRECTIONS: Array[Vector2] = [
	Vector2.RIGHT,
	Vector2.LEFT,
	Vector2.UP,
	Vector2.DOWN,
]

var failures: Array[String] = []


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	for player_scene in PLAYER_SCENES:
		await _test_player_scene(player_scene)

	if failures.is_empty():
		print("MULTIPLAYER_NAMEPLATE_TRANSFORM_SMOKE_TEST_OK")
		quit()
		return
	for failure in failures:
		push_error(failure)
	quit(1)


func _test_player_scene(player_scene: PackedScene) -> void:
	var viewport := SubViewport.new()
	viewport.name = "NameplateTestViewport"
	viewport.size = VIEWPORT_SIZE
	viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	root.add_child(viewport)

	var world := Node2D.new()
	world.name = "World"
	viewport.add_child(world)
	var player := player_scene.instantiate() as Player
	var scene_name := player_scene.resource_path.get_file()
	var authored_nameplate := player.get_node("Nameplate") as Node2D
	_expect(
		authored_nameplate != null and not authored_nameplate.visible,
		"%s 名牌必须在玩家场景资源中默认隐藏，不能依赖运行时补救。" % scene_name
	)
	player.position = Vector2(256.0, 192.0)
	world.add_child(player)

	var camera := Camera2D.new()
	camera.name = "Camera2D"
	camera.zoom = CAMERA_ZOOM
	camera.process_callback = Camera2D.CAMERA2D_PROCESS_PHYSICS
	player.add_child(camera)
	player.physics_interpolation_mode = Node.PHYSICS_INTERPOLATION_MODE_ON
	camera.physics_interpolation_mode = Node.PHYSICS_INTERPOLATION_MODE_INHERIT
	camera.make_current()

	await process_frame
	await physics_frame
	player.set_physics_process(false)
	camera.force_update_scroll()
	await process_frame

	_expect(not player.nameplate.visible, "%s 名牌必须在场景与单人默认状态下隐藏。" % scene_name)
	_expect(
		player.nameplate.get_parent() == player,
		"%s 名牌必须是玩家根节点的稳定视觉子节点。" % scene_name
	)
	_expect(
		player.nameplate.get_canvas() == player.get_canvas()
		and player.nameplate_label.get_canvas() == player.get_canvas()
		and player.nameplate.get_canvas_layer_node() == null
		and player.nameplate_label.get_canvas_layer_node() == null,
		"%s 名牌必须与玩家共享默认世界 canvas，不能再经过独立 CanvasLayer。" % scene_name
	)
	var content := player.nameplate.get_node("Content") as Node2D
	var label_material := player.nameplate_label.material as CanvasItemMaterial
	_expect(
		content != null and content.scale.is_equal_approx(EXPECTED_CONTENT_SCALE),
		"%s 名牌内容必须抵消标准战斗相机的 2× 缩放。" % scene_name
	)
	_expect(
		label_material != null
		and label_material.light_mode == CanvasItemMaterial.LIGHT_MODE_UNSHADED,
		"%s 名牌必须保持不受夜间 CanvasModulate 与 2D 灯光影响的可读性。" % scene_name
	)
	_expect(
		player.nameplate.position.is_equal_approx(EXPECTED_NAMEPLATE_ANCHOR),
		"%s 名牌锚点必须由场景固定在玩家头顶。" % scene_name
	)

	player.configure_multiplayer_control(1, true, "")
	_expect(not player.nameplate.visible, "%s 空名字不得在单人/未配置状态显示名牌。" % scene_name)
	player.configure_multiplayer_control(1, true, "Local", false, true)
	await process_frame
	_expect(
		player.nameplate.visible and player.nameplate_label.text == "Local",
		"%s 多人配置必须显示玩家场景自带的名牌。" % scene_name
	)
	_check_screen_geometry(player, scene_name)

	var baseline_screen_anchor := _get_nameplate_screen_anchor(player)
	var initial_player_position := player.global_position
	for facing_id in FACING_DIRECTIONS.size():
		player.call("_set_multiplayer_facing_id", facing_id)
		player.velocity = FACING_DIRECTIONS[facing_id] * 64.0
		player.call("_update_animation")
		_expect(
			player.nameplate.position.is_equal_approx(EXPECTED_NAMEPLATE_ANCHOR),
			"%s 朝向 %d 改变了名牌相对锚点。" % [scene_name, facing_id]
		)
		player.global_position = initial_player_position + FACING_DIRECTIONS[facing_id] * 64.0
		player.reset_physics_interpolation()
		camera.reset_physics_interpolation()
		camera.force_update_scroll()
		await process_frame
		_expect(
			_get_nameplate_screen_anchor(player).is_equal_approx(baseline_screen_anchor),
			"%s 朝向 %d 移动后，本地跟随相机中的名牌发生方向性屏幕偏移。"
			% [scene_name, facing_id]
		)

	player.global_position = initial_player_position
	player.reset_physics_interpolation()
	camera.reset_physics_interpolation()
	camera.force_update_scroll()
	var body_position_before_offset := player.body_sprite.position
	var visual_offset := Vector2(4.0, -3.0)
	player.call("_set_multiplayer_visual_offset", visual_offset)
	_expect(
		player.nameplate.position.is_equal_approx(EXPECTED_NAMEPLATE_ANCHOR + visual_offset)
		and (player.body_sprite.position - body_position_before_offset).is_equal_approx(visual_offset),
		"%s 远端平滑偏移必须由身体与名牌共同继承。" % scene_name
	)
	player.call("_set_multiplayer_visual_offset", Vector2.ZERO)

	_stop_audio_players(player)
	viewport.queue_free()
	await process_frame
	await physics_frame


func _check_screen_geometry(player: Player, scene_name: String) -> void:
	var label := player.nameplate_label
	var transform := label.get_global_transform_with_canvas()
	var top_left := transform * Vector2.ZERO
	var top_right := transform * Vector2(label.size.x, 0.0)
	var bottom_left := transform * Vector2(0.0, label.size.y)
	var screen_size := Vector2(
		top_left.distance_to(top_right),
		top_left.distance_to(bottom_left)
	)
	_expect(
		screen_size.is_equal_approx(EXPECTED_SCREEN_SIZE),
		"%s 在 2× 相机下的名牌屏幕尺寸错误：%s。" % [scene_name, screen_size]
	)
	var label_bottom_center := transform * Vector2(label.size.x * 0.5, label.size.y)
	_expect(
		label_bottom_center.is_equal_approx(_get_nameplate_screen_anchor(player)),
		"%s 名牌文字没有以底边中心对齐稳定锚点。" % scene_name
	)


func _get_nameplate_screen_anchor(player: Player) -> Vector2:
	return player.nameplate.get_global_transform_with_canvas().origin


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
