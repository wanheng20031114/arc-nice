extends SceneTree

const TOWER_SCENE := preload("res://scene/game_tower_defense.tscn")
const MINIMAP_SCENE := preload("res://scene/tower_defense_minimap.tscn")
const REMOTE_PLAYER_SCENE := preload("res://scene/player/weishidaier/player_weishidaier.tscn")
const ENEMY_SCENE := preload("res://scene/enemy/yuanshi_insect_basic.tscn")
const MAX_SAMPLE_RATE_HZ := 30.0
const EXPECTED_HOME_GATE_CELL_COUNT := 4

var failures: Array[String] = []


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	var game := TOWER_SCENE.instantiate() as GameTowerDefense
	_expect(game != null, "Tower-defense scene must instantiate for minimap verification.")
	if game == null:
		_finish()
		return
	game.auto_start_waves = false
	root.add_child(game)
	current_scene = game
	await process_frame
	await process_frame

	var independent_minimap := MINIMAP_SCENE.instantiate() as TowerDefenseMinimap
	_expect(
		independent_minimap != null,
		"Minimap must remain an independent instantiable scene."
	)
	if independent_minimap != null:
		independent_minimap.free()
	var minimap := game.tower_defense_minimap
	_expect(minimap != null, "Tower-defense scene must include the local minimap scene.")
	if minimap == null:
		game.queue_free()
		await process_frame
		_finish()
		return

	_verify_scene_structure(game, minimap)
	_verify_static_topology(minimap.minimap_canvas)
	_verify_projection_and_coordinate(game, minimap)
	await _verify_dynamic_markers(game, minimap.minimap_canvas)

	game.queue_free()
	await process_frame
	await process_frame
	_finish()


func _verify_scene_structure(
	game: GameTowerDefense,
	minimap: TowerDefenseMinimap
) -> void:
	_expect(minimap.layer == 9, "Minimap must render above the world in its own CanvasLayer.")
	_expect(
		minimap.layer < game.wave_hud.layer,
		"WaveHUD victory and defeat results must cover the minimap."
	)
	_expect(
		minimap.layer < game.currency_hud.layer
		and minimap.layer < game.home_base_hud.layer,
		"Primary tower-defense HUD layers must remain above the minimap."
	)
	_expect(
		is_equal_approx(minimap.sample_timer.wait_time, TowerDefenseMinimap.SAMPLE_INTERVAL_SECONDS),
		"Minimap must use its authored stagger timer interval."
	)
	_expect(
		1.0 / minimap.sample_timer.wait_time <= MAX_SAMPLE_RATE_HZ,
		"The aggregate minimap sample timer must not exceed 30 Hz."
	)
	_expect(
		not minimap.sample_timer.one_shot
		and minimap.sample_timer.timeout.is_connected(minimap._on_sample_timer_timeout),
		"The native Timer must repeat through the scene-authored timeout connection."
	)
	var canvas_size := minimap.minimap_canvas.size
	_expect(
		is_equal_approx(canvas_size.x / canvas_size.y, 16.0 / 9.0),
		"The authored map canvas must remain 16:9."
	)
	_expect(
		minimap.minimap_canvas.get_node("StaticLayer") is Control
		and minimap.minimap_canvas.get_node("DynamicLayer") is Control,
		"Static topology and dynamic markers must use separate draw layers."
	)
	_expect(
		minimap.find_children("*", "SubViewport", true, false).is_empty(),
		"The minimap must not render the world a second time through a SubViewport."
	)


func _verify_static_topology(canvas: TowerDefenseMinimapCanvas) -> void:
	var layer := canvas.static_layer
	_expect(not layer.wall_world_positions.is_empty(), "Minimap must cache wall cells.")
	_expect(not layer.water_world_positions.is_empty(), "Minimap must cache water cells.")
	_expect(
		layer.home_gate_world_positions.size() == EXPECTED_HOME_GATE_CELL_COUNT,
		"Minimap must render every blue Home gate cell."
	)
	_expect(
		not layer.enemy_gate_world_positions.is_empty(),
		"Minimap must render the authored red enemy gates."
	)
	_expect(
		canvas.dynamic_layer.plant_world_positions.is_empty(),
		"An empty PlantContainer must produce no phantom minimap plants."
	)


func _verify_projection_and_coordinate(
	game: GameTowerDefense,
	minimap: TowerDefenseMinimap
) -> void:
	var canvas := minimap.minimap_canvas
	var expected_coordinate := game.ground_tile_map_layer.local_to_map(
		game.ground_tile_map_layer.to_local(game.player.global_position)
	)
	_expect(
		canvas.get_tile_coordinate() == expected_coordinate,
		"Coordinate label data must use integer TileMapLayer coordinates."
	)
	_expect(
		minimap.coordinate_label.text == "瓦片坐标：%d, %d" % [
			expected_coordinate.x,
			expected_coordinate.y,
		],
		"The integer tile coordinate must be displayed below the map."
	)

	var view_rect := canvas.static_layer.get_projected_view_rect()
	_expect(
		is_equal_approx(view_rect.size.x / canvas.static_layer.size.x, 1.0 / 3.0),
		"The current-view frame width must occupy one third of the minimap."
	)
	_expect(
		is_equal_approx(view_rect.size.y / canvas.static_layer.size.y, 1.0 / 3.0),
		"The current-view frame height must occupy one third of the minimap."
	)
	_expect(
		canvas.dynamic_layer.local_player_world_position.is_equal_approx(
			game.player.global_position
		),
		"The local green marker must sample the local player node directly."
	)
	_expect(
		TowerDefenseMinimapDynamicLayer.LOCAL_PLAYER_COLOR
		== Color(0.18, 1.0, 0.38, 1.0),
		"The local-player marker must remain green."
	)
	var projected_origin := canvas.static_layer._world_to_canvas(Vector2.ZERO)
	var projected_east := canvas.static_layer._world_to_canvas(Vector2(16.0, 0.0))
	var projected_north := canvas.static_layer._world_to_canvas(Vector2(0.0, -16.0))
	_expect(
		projected_east.x > projected_origin.x
		and is_equal_approx(projected_east.y, projected_origin.y)
		and projected_north.y < projected_origin.y
		and is_equal_approx(projected_north.x, projected_origin.x),
		"World axes must project directly so north remains up on the minimap."
	)

	var previous_coordinate := expected_coordinate
	game.player.global_position += Vector2(16.0, 0.0)
	canvas.sample_next_phase()
	canvas.sample_next_phase()
	_expect(
		canvas.get_tile_coordinate() == previous_coordinate + Vector2i.RIGHT,
		"Staggered sampling must refresh the local tile coordinate on its camera phase."
	)


func _verify_dynamic_markers(
	game: GameTowerDefense,
	canvas: TowerDefenseMinimapCanvas
) -> void:
	var remote_player := REMOTE_PLAYER_SCENE.instantiate() as Player
	remote_player.uses_local_input = false
	remote_player.set_physics_process(false)
	game.add_child(remote_player)
	remote_player.global_position = game.player.global_position + Vector2(48.0, 0.0)

	var enemy := ENEMY_SCENE.instantiate() as Enemy
	enemy.set_process(false)
	enemy.set_physics_process(false)
	game.enemy_container.add_child(enemy)
	enemy.global_position = game.player.global_position + Vector2(-48.0, -32.0)

	var plant := PlantDefense.new()
	game.plant_container.add_child(plant)
	plant.global_position = game.player.global_position + Vector2(24.0, 48.0)
	await process_frame

	canvas._sample_world_entities()
	_expect(
		canvas.dynamic_layer.remote_player_world_positions.has(remote_player.global_position),
		"A sampled remote player must enter the white-marker data layer."
	)
	_expect(
		canvas.dynamic_layer.enemy_world_positions.has(enemy.global_position),
		"A sampled living enemy must enter the red-marker data layer."
	)
	_expect(
		canvas.dynamic_layer.plant_world_positions.has(plant.global_position),
		"A sampled plant must enter the light-green square data layer."
	)
	_expect(
		TowerDefenseMinimapDynamicLayer.REMOTE_PLAYER_COLOR == Color(0.96, 0.98, 1.0, 1.0),
		"Remote-player markers must remain white."
	)
	_expect(
		TowerDefenseMinimapDynamicLayer.ENEMY_COLOR == Color(1.0, 0.18, 0.14, 1.0),
		"Enemy markers must remain red."
	)
	_expect(
		TowerDefenseMinimapDynamicLayer.PLANT_COLOR == Color(0.52, 0.91, 0.54, 0.96),
		"Plant markers must remain light green."
	)


func _finish() -> void:
	if failures.is_empty():
		print("TOWER_DEFENSE_MINIMAP_SMOKE_TEST_OK")
		quit()
		return
	for failure in failures:
		push_error(failure)
	quit(1)


func _expect(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)
